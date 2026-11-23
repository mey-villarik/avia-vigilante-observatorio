#!/usr/bin/env python3
"""Despierta a Hermes SOLO cuando hay eventos compuestos (28), cambios en noticias (31), fichas de riesgo (32)
o probabilidades de señales confirmadas (33) pendientes.

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
     Si hay probabilidades por ajustar y existe HERMES_CRON_PROB, lanza esa tarea (skill avia-probabilidad). Sin ella,
     las señales confirmadas se quedan con la probabilidad base de la base de datos (ver docs/probabilidad-senales.md).
  3. Anota en vigilante.system_logs cuántos había y si Hermes arrancó.

Tiene su propio candado (/tmp/avia-eventos.lock): NO pongas flock en el crontab.

Freno (para no gastar tokens en bucle si Hermes no consigue guardar):
  - Entre dos lanzamientos de la misma tarea pasan al menos HERMES_ESPERA_MIN minutos (10).
  - Si tras HERMES_INTENTOS_SIN_AVANCE lanzamientos seguidos (2) los pendientes de esa tarea no bajan, o el lanzamiento
    falla, el script deja de lanzarla: espera 30 min, luego 60, 120, 240… hasta HERMES_ESPERA_MAX_MIN (360 = 6 h).
    Lo anota una vez en system_logs (nivel warn). En cuanto los pendientes bajan o llegan a 0, todo vuelve a lo normal.
  - Nunca más de HERMES_MAX_DIA lanzamientos de una misma tarea por día UTC (48).
  El estado se guarda en HERMES_ESTADO (por defecto /root/avia/despertar_estado.json).

Uso:
  despertar_hermes.py            # lo normal
  despertar_hermes.py --contar   # solo dice cuántos eventos esperan, no lanza nada
  despertar_hermes.py --estado   # muestra el freno de cada tarea (intentos sin avance, espera, lanzamientos hoy)
  despertar_hermes.py --reiniciar-freno   # borra el freno (por ejemplo, tras arreglar el fallo a mano)

Variables (en /etc/avia/supabase.env o en el archivo de AVIA_SUPABASE_ENV; NUNCA en Git):
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE=orbita-bolivia
  HERMES_CRON_EVENTOS=<id de la tarea de Hermes «Interpretar eventos»>
  HERMES_CRON_CAMBIOS (opcional) = id de una tarea aparte para los cambios; sin ella, se usa la de eventos
  HERMES_CRON_FICHAS (opcional) = id de la tarea «Fichas de aprobación» (skill avia-ficha-aprobacion)
  HERMES_CRON_PROB (opcional) = id de la tarea «Probabilidad de señales» (skill avia-probabilidad)
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
from datetime import datetime, timedelta, timezone

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


def ordenes_hermes(n_eventos: int, n_cambios: int, n_fichas: int = 0, n_prob: int = 0) -> list[tuple[str, list[str], int]]:
    """Las tareas de Hermes que hay que lanzar (sin repetir la misma): (clave, orden, pendientes que atiende)."""
    if os.environ.get('HERMES_CMD'):
        return [('HERMES_CMD', shlex.split(os.environ['HERMES_CMD']), n_eventos + n_cambios + n_fichas + n_prob)]
    ev, ca = os.environ.get('HERMES_CRON_EVENTOS'), os.environ.get('HERMES_CRON_CAMBIOS')
    tareas: dict[str, int] = {}
    if n_cambios and (ca or ev):
        tareas[ca or ev] = tareas.get(ca or ev, 0) + n_cambios   # sin tarea propia, la de eventos también interpreta cambios
    if n_eventos and ev:
        tareas[ev] = tareas.get(ev, 0) + n_eventos
    fi = os.environ.get('HERMES_CRON_FICHAS')
    if n_fichas and fi:
        tareas[fi] = tareas.get(fi, 0) + n_fichas
    pr = os.environ.get('HERMES_CRON_PROB')
    if n_prob and pr:
        tareas[pr] = tareas.get(pr, 0) + n_prob
    return [(t, ['docker', 'exec', 'hermes', 'hermes', 'cron', 'run', t], n) for t, n in tareas.items()]


# ---------------------------------------------------------------- freno

def _num(var: str, defecto: int) -> int:
    try:
        return max(0, int(os.environ.get(var, defecto)))
    except ValueError:
        return defecto


def ruta_estado() -> str:
    if os.environ.get('HERMES_ESTADO'):
        return os.environ['HERMES_ESTADO']
    base = '/root/avia' if os.path.isdir('/root/avia') else os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, 'despertar_estado.json')


def leer_estado() -> dict:
    try:
        with open(ruta_estado(), encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def guardar_estado(estado: dict) -> None:
    ruta = ruta_estado()
    tmp = ruta + '.tmp'
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(estado, f, ensure_ascii=False, indent=1)
        os.replace(tmp, ruta)
    except OSError as e:
        log(f'No pude guardar el freno en {ruta}: {e}')


def _fecha(txt: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(txt) if txt else None
    except ValueError:
        return None


def decidir(est: dict, pendientes: int, ahora: datetime) -> tuple[bool, str]:
    """¿Se lanza ya esta tarea? Actualiza `est` (estado de UNA tarea). Devuelve (lanzar, motivo)."""
    espera_min = _num('HERMES_ESPERA_MIN', 10)
    limite = max(1, _num('HERMES_INTENTOS_SIN_AVANCE', 2))
    espera_max = _num('HERMES_ESPERA_MAX_MIN', 360)
    max_dia = _num('HERMES_MAX_DIA', 48)

    hoy = ahora.date().isoformat()
    if est.get('dia') != hoy:
        est['dia'], est['hoy'] = hoy, 0
    if max_dia and est.get('hoy', 0) >= max_dia:
        return False, f'ya se lanzó {est["hoy"]} veces hoy (tope HERMES_MAX_DIA={max_dia})'

    hasta = _fecha(est.get('espera_hasta'))
    if hasta and ahora < hasta:
        return False, f'en espera hasta {hasta.isoformat(timespec="minutes")} ({est.get("sin_avance", 0)} intentos sin avance)'
    reintento = hasta is not None          # la espera acaba de terminar: se prueba una vez más

    ultimo = _fecha(est.get('ultimo'))
    if ultimo is not None and ahora - ultimo < timedelta(minutes=espera_min):
        return False, f'último lanzamiento hace menos de {espera_min} min'
    if ultimo is not None and not reintento:
        # ¿avanzó desde el último lanzamiento? Si los pendientes no bajan, Hermes no está guardando.
        if pendientes >= int(est.get('pendientes', 0)) or est.get('fallo'):
            est['sin_avance'] = int(est.get('sin_avance', 0)) + 1
        else:
            est['sin_avance'] = 0

    sin_avance = int(est.get('sin_avance', 0))
    if sin_avance >= limite and not reintento:
        minutos = 30 * 2 ** (sin_avance - limite)
        if espera_max:
            minutos = min(minutos, espera_max)
        est['espera_hasta'] = (ahora + timedelta(minutes=minutos)).isoformat(timespec='seconds')
        est['avisar'] = True
        return False, f'{sin_avance} lanzamientos seguidos sin que bajen los pendientes ({pendientes}): espero {minutos} min'
    return True, ''


def anotar_lanzamiento(est: dict, pendientes: int, ok: bool, ahora: datetime) -> None:
    est['ultimo'] = ahora.isoformat(timespec='seconds')
    est['pendientes'] = pendientes
    est['fallo'] = not ok
    est['hoy'] = int(est.get('hoy', 0)) + 1
    est.pop('espera_hasta', None)


def main() -> int:
    ap = argparse.ArgumentParser(description='Despierta a Hermes si hay eventos compuestos o cambios por interpretar')
    ap.add_argument('--contar', action='store_true', help='solo contar, sin lanzar a Hermes')
    ap.add_argument('--estado', action='store_true', help='mostrar el freno de cada tarea')
    ap.add_argument('--reiniciar-freno', action='store_true', help='borrar el freno de todas las tareas')
    a = ap.parse_args()

    if a.estado:
        print(json.dumps(leer_estado(), ensure_ascii=False, indent=1) or '{}')
        return 0
    if a.reiniciar_freno:
        guardar_estado({})
        log(f'Freno borrado ({ruta_estado()})')
        return 0

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
    n_pr = 0
    if os.environ.get('HERMES_CRON_PROB') or a.contar:
        try:
            n_pr = int(rpc('probabilidades_pendientes_hermes', {'p_cliente': cliente}) or 0)
        except Exception as e:  # noqa: BLE001 — sin el 33 no hay probabilidades
            log(f'No pude contar las probabilidades ({str(e)[:120]}). ¿Está ejecutado el 33_probabilidad_senales.sql?')
    resumen = f'{n_ev} eventos, {n_ca} cambios, {n_fi} fichas y {n_pr} probabilidades'
    if a.contar:
        log(f'Por hacer: {resumen}')
        return 0
    n = n_ev + n_ca + (n_fi if os.environ.get('HERMES_CRON_FICHAS') else 0) + (n_pr if os.environ.get('HERMES_CRON_PROB') else 0)
    estado = leer_estado()
    if n == 0:
        if estado:
            guardar_estado({})   # todo atendido: el freno vuelve a cero
        log(f'Por hacer: {resumen} — Hermes no se despierta')
        return 0

    ordenes = ordenes_hermes(n_ev, n_ca, n_fi, n_pr)
    if not ordenes:
        log(f'Hay {resumen}, pero falta HERMES_CRON_EVENTOS (o HERMES_CMD) en el archivo de variables')
        return 2
    ahora = datetime.now(timezone.utc)
    claves = {c for c, _, _ in ordenes}
    for c in list(estado):
        if c not in claves:
            del estado[c]          # esa tarea ya no tiene pendientes: su freno vuelve a cero
    ok, detalles, lanzadas, frenos = True, [], 0, []
    for clave, orden, pend in ordenes:
        est = estado.setdefault(clave, {})
        lanzar, motivo = decidir(est, pend, ahora)
        if not lanzar:
            log(f'Hay {resumen}, pero no lanzo {clave}: {motivo}')
            if est.pop('avisar', False):
                frenos.append(f'{clave}: {motivo}')
            continue
        log(f'Hay {resumen}: lanzo a Hermes ({" ".join(orden)})')
        try:
            r = subprocess.run(orden, capture_output=True, text=True, timeout=TIMEOUT_HERMES, check=False)
            ok_i, detalle = r.returncode == 0, (r.stdout[-500:] + r.stderr[-500:]).strip()
        except (OSError, subprocess.TimeoutExpired) as e:
            ok_i, detalle = False, f'{type(e).__name__}: {e}'
        log(('Hermes terminó' if ok_i else 'Hermes falló') + (f': {detalle[:300]}' if detalle else ''))
        anotar_lanzamiento(est, pend, ok_i, ahora)
        ok, detalles, lanzadas = ok and ok_i, detalles + [detalle], lanzadas + 1
    guardar_estado(estado)
    for f in frenos:
        try:
            rpc('registrar_log', {'p_cliente': cliente, 'p_proceso': 'eventos', 'p_nivel': 'warn',
                                  'p_mensaje': 'Freno: Hermes no avanza, dejo de despertarlo un rato',
                                  'p_detalle': {'freno': f}, 'p_costo_usd': None, 'p_codigo_fuente': None})
        except Exception as e:  # noqa: BLE001
            log(f'No pude anotar el freno en system_logs: {str(e)[:200]}')
    if not lanzadas:
        return 0
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
