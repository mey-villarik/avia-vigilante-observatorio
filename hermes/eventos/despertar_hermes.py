#!/usr/bin/env python3
"""Despierta a Hermes SOLO cuando hay eventos compuestos (28), cambios en noticias (31) o fichas de riesgo (32) pendientes.

Hermes es el cerebro: él decide qué significa cada evento, a quién afecta y qué se recomienda
(skill «interpretar-eventos»). Este script no usa IA: pregunta a Supabase cuántos eventos esperan
(vigilante.eventos_pendientes_hermes) y, si hay alguno, lanza la tarea programada de Hermes.
Si no hay nada, termina sin gastar un solo token.

Cada vez que se ejecuta (cron del VPS, p. ej. cada 5 minutos):
  1. Cuenta los eventos, los cambios por interpretar y las fichas de aprobación por preparar. Todo 0 → termina.
  2. Lanza la tarea de Hermes: HERMES_CMD (por defecto: docker exec hermes hermes cron run $HERMES_CRON_EVENTOS).
     Si hay cambios y existe HERMES_CRON_CAMBIOS, lanza esa tarea; si no, la de eventos (su prompt debe
     incluir los cambios: ver docs/cambios-noticias.md).
     Si hay fichas y existe HERMES_CRON_FICHAS, lanza esa tarea (skill avia-ficha-aprobacion). Sin ella, las
     fichas no despiertan a Hermes (ver docs/ficha-aprobacion.md).
  3. Anota en vigilante.system_logs cuántos había y si Hermes arrancó.

Tiene su propio candado (/tmp/avia-eventos.lock): NO pongas flock en el crontab.

Uso:
  despertar_hermes.py            # lo normal
  despertar_hermes.py --contar   # solo dice cuántos eventos esperan, no lanza nada

Variables (en /etc/avia/supabase.env o en el archivo de AVIA_SUPABASE_ENV; NUNCA en Git):
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE=orbita-bolivia
  HERMES_CRON_EVENTOS=<id de la tarea de Hermes «Interpretar eventos»>
  HERMES_CRON_CAMBIOS (opcional) = id de una tarea aparte para los cambios; sin ella, se usa la de eventos
  HERMES_CRON_FICHAS (opcional) = id de la tarea «Fichas de aprobación» (skill avia-ficha-aprobacion)
  HERMES_CMD (opcional) = orden completa para lanzar a Hermes; sustituye a la de por defecto
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

TIMEOUT_HERMES = 15 * 60   # una ronda de Hermes no debería durar más


def cargar_env() -> None:
    for ruta in (os.environ.get('AVIA_SUPABASE_ENV'), '/etc/avia/supabase.env', os.path.expanduser('~/avia/supabase.env')):
        if ruta and os.path.isfile(ruta):
            with open(ruta, encoding='utf-8') as f:
                for linea in f:
                    linea = linea.strip()
                    if linea and not linea.startswith('#') and '=' in linea:
                        k, v = linea.split('=', 1)
                        os.environ.setdefault(k.replace('export ', '').strip(), v.strip().strip('"').strip("'"))
            return


def log(msg: str) -> None:
    print(f'{datetime.now(timezone.utc).isoformat(timespec="seconds")} {msg}', flush=True)


def rpc(fn: str, args: dict) -> object:
    url = os.environ['SUPABASE_URL'].rstrip('/')
    key = os.environ['SUPABASE_SERVICE_ROLE_KEY']
    cab = {'apikey': key, 'Content-Type': 'application/json', 'Content-Profile': 'vigilante', 'Accept-Profile': 'vigilante'}
    if not key.startswith('sb_'):
        cab['Authorization'] = f'Bearer {key}'
    req = urllib.request.Request(f'{url}/rest/v1/rpc/{fn}', data=json.dumps(args).encode(), headers=cab, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            cuerpo = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'HTTP {e.code} en {fn}: {e.read()[:300].decode(errors="replace")}') from None
    return json.loads(cuerpo) if cuerpo else None


def ordenes_hermes(n_eventos: int, n_cambios: int, n_fichas: int = 0) -> list[list[str]]:
    """Las tareas de Hermes que hay que lanzar (sin repetir la misma)."""
    if os.environ.get('HERMES_CMD'):
        return [shlex.split(os.environ['HERMES_CMD'])]
    ev, ca = os.environ.get('HERMES_CRON_EVENTOS'), os.environ.get('HERMES_CRON_CAMBIOS')
    tareas: list[str] = []
    if n_cambios and (ca or ev):
        tareas.append(ca or ev)          # sin tarea propia, la de eventos también interpreta cambios
    if n_eventos and ev and ev not in tareas:
        tareas.append(ev)
    fi = os.environ.get('HERMES_CRON_FICHAS')
    if n_fichas and fi and fi not in tareas:
        tareas.append(fi)
    return [['docker', 'exec', 'hermes', 'hermes', 'cron', 'run', t] for t in tareas]


def main() -> int:
    ap = argparse.ArgumentParser(description='Despierta a Hermes si hay eventos compuestos o cambios por interpretar')
    ap.add_argument('--contar', action='store_true', help='solo contar, sin lanzar a Hermes')
    a = ap.parse_args()

    cargar_env()
    for v in ('SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'):
        if not os.environ.get(v):
            log(f'Falta {v}: revisa /etc/avia/supabase.env')
            return 2
    cliente = os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia')

    try:
        import fcntl
        candado = open('/tmp/avia-eventos.lock', 'w')  # noqa: SIM115 — se mantiene abierto mientras dura
        fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log('Hermes sigue interpretando la ronda anterior: salgo')
        return 0
    except ImportError:
        pass

    try:
        n_ev = int(rpc('eventos_pendientes_hermes', {'p_cliente': cliente}) or 0)
    except Exception as e:  # noqa: BLE001
        log(f'No pude contar los eventos ({str(e)[:200]}). ¿Está ejecutado el 28_eventos_compuestos.sql?')
        n_ev = 0
    try:
        n_ca = int(rpc('cambios_pendientes_hermes', {'p_cliente': cliente}) or 0)
    except Exception as e:  # noqa: BLE001 — sin el 31 solo hay eventos
        log(f'No pude contar los cambios ({str(e)[:120]}). ¿Está ejecutado el 31_cambios_noticias.sql?')
        n_ca = 0
    n_fi = 0
    if os.environ.get('HERMES_CRON_FICHAS') or a.contar:
        try:
            n_fi = int(rpc('fichas_pendientes_hermes', {'p_cliente': cliente}) or 0)
        except Exception as e:  # noqa: BLE001 — sin el 32 no hay fichas
            log(f'No pude contar las fichas ({str(e)[:120]}). ¿Está ejecutado el 32_ficha_aprobacion.sql?')
    resumen = f'{n_ev} eventos, {n_ca} cambios y {n_fi} fichas'
    if a.contar:
        log(f'Por hacer: {resumen}')
        return 0
    n = n_ev + n_ca + (n_fi if os.environ.get('HERMES_CRON_FICHAS') else 0)
    if n == 0:
        log(f'Por hacer: {resumen} — Hermes no se despierta')
        return 0

    ordenes = ordenes_hermes(n_ev, n_ca, n_fi)
    if not ordenes:
        log(f'Hay {resumen}, pero falta HERMES_CRON_EVENTOS (o HERMES_CMD) en el archivo de variables')
        return 2
    ok, detalles = True, []
    for orden in ordenes:
        log(f'Hay {resumen}: lanzo a Hermes ({" ".join(orden)})')
        try:
            r = subprocess.run(orden, capture_output=True, text=True, timeout=TIMEOUT_HERMES, check=False)
            ok_i, detalle = r.returncode == 0, (r.stdout[-500:] + r.stderr[-500:]).strip()
        except (OSError, subprocess.TimeoutExpired) as e:
            ok_i, detalle = False, f'{type(e).__name__}: {e}'
        log(('Hermes terminó' if ok_i else 'Hermes falló') + (f': {detalle[:300]}' if detalle else ''))
        ok, detalles = ok and ok_i, detalles + [detalle]
    detalle = ' | '.join(d for d in detalles if d)
    try:
        rpc('registrar_log', {'p_cliente': cliente, 'p_proceso': 'eventos', 'p_nivel': 'info' if ok else 'error',
                              'p_mensaje': f'Hermes {"lanzado" if ok else "falló"} con {resumen}',
                              'p_detalle': {'salida': detalle[:1000]}, 'p_costo_usd': None, 'p_codigo_fuente': None})
    except Exception as e:  # noqa: BLE001 — el registro es secundario
        log(f'No pude anotar en system_logs: {str(e)[:200]}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
