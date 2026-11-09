#!/usr/bin/env python3
"""Analizador del Vigilante AVIA: clasifica en lote SOLO las noticias nuevas o cambiadas.

No es Hermes. Es una llamada breve a un modelo barato (DeepSeek u otro compatible con la API
de OpenAI) con instrucciones cortas (prompt_clasificador.md). Hermes queda para las tareas que
necesitan investigar (vigilante.tareas_agente).

Cada vez que se ejecuta (cron o n8n, p. ej. cada 10 minutos):
  1. Pide a Supabase un lote con vigilante.lote_para_clasificar(): versiones que pasaron el filtro
     sin IA y que aún no tienen clasificación. Si no hay nada, termina SIN llamar al modelo.
  2. Manda el lote al modelo y valida la respuesta (solo claves del lote, valores permitidos).
  3. Guarda el resultado con vigilante.guardar_clasificacion(): la base crea o actualiza señales,
     oportunidades y tareas para Hermes, y pone la procedencia (fuente, enlace) desde las noticias.
  4. Anota tokens y coste en vigilante.system_logs.

Uso:
  analizador.py                 # lo normal
  analizador.py --prueba        # pide un lote y muestra la respuesta del modelo, sin guardar (las noticias vuelven a la cola)
  analizador.py --lotes 3       # como máximo 3 lotes en esta ejecución (por defecto 4)

Variables (en /etc/avia/supabase.env o en el archivo de AVIA_SUPABASE_ENV; NUNCA en Git):
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE=orbita-bolivia
  LLM_API_KEY (o DEEPSEEK_API_KEY)
  LLM_BASE_URL=https://api.deepseek.com   LLM_MODEL=deepseek-chat
  LLM_PRECIO_ENTRADA / LLM_PRECIO_SALIDA  (USD por millón de tokens, para anotar el coste; opcional)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

LOTE = 15
TIMEOUT = 120
AQUI = Path(__file__).resolve().parent
PROMPT = AQUI / 'prompt_clasificador.md'

NATURALEZAS = {'riesgo', 'oportunidad', 'mixta'}
CATEGORIAS = {'clima', 'salud', 'vial', 'seguridad', 'conectividad', 'eventos', 'financiamiento', 'normativa', 'mercados'}
PRIORIDADES = {'alta', 'media', 'baja'}
TAREAS = {'corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida'}
FECHA = re.compile(r'^\d{4}-\d{2}-\d{2}$')
# lo que el modelo NO puede decidir: la procedencia la pone la base
PROHIBIDOS = {'fuente_id', 'fuente', 'enlace_oficial', 'enlace', 'url', 'codigo', 'noticias', 'ids'}


def cargar_env() -> None:
    rutas = [os.environ.get('AVIA_SUPABASE_ENV'), '/etc/avia/supabase.env', os.path.expanduser('~/avia/supabase.env')]
    for ruta in rutas:
        if ruta and os.path.isfile(ruta):
            with open(ruta, encoding='utf-8') as f:
                for linea in f:
                    linea = linea.strip()
                    if not linea or linea.startswith('#') or '=' not in linea:
                        continue
                    k, v = linea.split('=', 1)
                    os.environ.setdefault(k.replace('export ', '').strip(), v.strip().strip('"').strip("'"))
            return


def log(msg: str) -> None:
    print(f'{datetime.now(timezone.utc).isoformat(timespec="seconds")} {msg}', flush=True)


def post(url: str, cuerpo: dict, cabeceras: dict, timeout: int = 60) -> object:
    req = urllib.request.Request(url, data=json.dumps(cuerpo).encode(), headers={'Content-Type': 'application/json', **cabeceras}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            datos = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'HTTP {e.code} en {url}: {e.read()[:300].decode(errors="replace")}') from None
    return json.loads(datos) if datos else None


class Supabase:
    def __init__(self) -> None:
        self.url = os.environ['SUPABASE_URL'].rstrip('/')
        self.key = os.environ['SUPABASE_SERVICE_ROLE_KEY']
        self.cliente = os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia')

    def rpc(self, fn: str, args: dict) -> object:
        cab = {'apikey': self.key, 'Content-Profile': 'vigilante', 'Accept-Profile': 'vigilante'}
        if not self.key.startswith('sb_'):
            cab['Authorization'] = f'Bearer {self.key}'
        return post(f'{self.url}/rest/v1/rpc/{fn}', args, cab)


def prompt() -> tuple[str, str]:
    texto = PROMPT.read_text(encoding='utf-8')
    m = re.search(r'version:\s*([\w.\-]+)', texto)
    return texto, (m.group(1) if m else 'clasificador')


def llamar_modelo(sistema: str, lote: list[dict]) -> tuple[list[dict], dict]:
    base = os.environ.get('LLM_BASE_URL', 'https://api.deepseek.com').rstrip('/')
    clave = os.environ.get('LLM_API_KEY') or os.environ.get('DEEPSEEK_API_KEY')
    if not clave:
        raise RuntimeError('Falta LLM_API_KEY (o DEEPSEEK_API_KEY) en el archivo de variables')
    modelo = os.environ.get('LLM_MODEL', 'deepseek-chat')
    # al modelo solo le llega lo necesario para clasificar
    entrada = [{k: n.get(k) for k in ('clave', 'titulo', 'texto', 'fuente', 'fuente_tipo', 'fuentes_que_coinciden', 'publicado_en',
                                      'territorios', 'oportunidad_candidata', 'es_actualizacion', 'senal_existente')} for n in lote]
    r = post(f'{base}/chat/completions', {
        'model': modelo, 'temperature': 0, 'max_tokens': 4000,
        'response_format': {'type': 'json_object'},
        'messages': [{'role': 'system', 'content': sistema},
                     {'role': 'user', 'content': json.dumps({'noticias': entrada}, ensure_ascii=False)}],
    }, {'Authorization': f'Bearer {clave}'}, timeout=TIMEOUT)
    contenido = r['choices'][0]['message']['content']
    datos = json.loads(re.sub(r'^```(json)?|```$', '', contenido.strip()).strip())
    uso = r.get('usage') or {}
    te, ts = int(uso.get('prompt_tokens') or 0), int(uso.get('completion_tokens') or 0)
    pe, ps = float(os.environ.get('LLM_PRECIO_ENTRADA') or 0), float(os.environ.get('LLM_PRECIO_SALIDA') or 0)
    return (datos.get('resultados') if isinstance(datos, dict) else datos) or [], {
        'modelo': modelo, 'tokens_entrada': te, 'tokens_salida': ts, 'costo_usd': round((te * pe + ts * ps) / 1e6, 6)}


def limpiar(res: list, claves: set[int]) -> list[dict]:
    """Solo claves del lote, valores permitidos y nada de procedencia."""
    vistos, ok = set(), []
    for x in res if isinstance(res, list) else []:
        if not isinstance(x, dict):
            continue
        try:
            clave = int(x.get('clave'))
        except (TypeError, ValueError):
            continue
        if clave not in claves or clave in vistos:
            continue
        vistos.add(clave)
        x = {k: v for k, v in x.items() if k not in PROHIBIDOS}
        x['clave'] = clave
        x['relevante'] = bool(x.get('relevante'))
        if x.get('naturaleza') not in NATURALEZAS:
            x.pop('naturaleza', None)
        if x.get('categoria') not in CATEGORIAS:
            x.pop('categoria', None)
        if x.get('prioridad') not in PRIORIDADES:
            x.pop('prioridad', None)
        for k in ('fecha_evento_inicio', 'fecha_evento_fin', 'plazo_hasta'):
            if not (isinstance(x.get(k), str) and FECHA.match(x[k])):
                x.pop(k, None)
        if not isinstance(x.get('departamentos'), list):
            x.pop('departamentos', None)
        try:
            x['confianza'] = max(0.0, min(1.0, float(x['confianza']))) if 'confianza' in x else None
        except (TypeError, ValueError):
            x['confianza'] = None
        op = x.get('oportunidad')
        if not (isinstance(op, dict) and op.get('hecho') and op.get('tipo')):
            x.pop('oportunidad', None)
        t = x.get('tarea')
        if not (x.get('necesita_agente') and isinstance(t, dict) and t.get('tipo') in TAREAS):
            x['necesita_agente'] = False
            x.pop('tarea', None)
        ok.append(x)
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description='Analizador breve del Vigilante AVIA (no Hermes)')
    ap.add_argument('--prueba', action='store_true', help='clasificar un lote y mostrarlo sin guardar')
    ap.add_argument('--lotes', type=int, default=4, help='lotes como máximo en esta ejecución')
    a = ap.parse_args()

    cargar_env()
    for v in ('SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'):
        if not os.environ.get(v):
            log(f'Falta {v}: revisa /etc/avia/supabase.env')
            return 2
    try:
        import fcntl
        candado = open('/tmp/avia-analizador.lock', 'w')  # noqa: SIM115 — se mantiene abierto mientras dura
        fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log('Otra ejecución sigue en marcha: salgo')
        return 0
    except ImportError:
        pass

    sb = Supabase()
    sistema, version = prompt()
    total = {'lotes': 0, 'noticias': 0, 'tokens_entrada': 0, 'tokens_salida': 0, 'costo_usd': 0.0}
    for _ in range(1 if a.prueba else max(a.lotes, 1)):
        lote = sb.rpc('lote_para_clasificar', {'p_cliente': sb.cliente, 'p_limite': LOTE}) or []
        if not lote:
            log('Nada nuevo que clasificar: no se llama al modelo')
            break
        ids = [i for n in lote for i in n['ids']]
        try:
            res, uso = llamar_modelo(sistema, lote)
        except Exception as e:  # noqa: BLE001 — si el modelo falla, las noticias vuelven a la cola
            log(f'El modelo falló ({type(e).__name__}: {str(e)[:200]}): devuelvo {len(ids)} noticias a la cola')
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': ids, 'p_estado': 'nuevo', 'p_motivo': None})
            sb.rpc('registrar_log', {'p_cliente': sb.cliente, 'p_proceso': 'clasificador', 'p_nivel': 'error',
                                     'p_mensaje': f'Fallo del modelo: {str(e)[:300]}', 'p_detalle': None,
                                     'p_costo_usd': None, 'p_codigo_fuente': None})
            return 1
        limpios = limpiar(res, {n['clave'] for n in lote})
        if a.prueba:
            print(json.dumps({'lote': lote, 'resultado': limpios, 'uso': uso}, ensure_ascii=False, indent=2))
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': ids, 'p_estado': 'nuevo', 'p_motivo': None})
            return 0
        # lo que el modelo no devolvió vuelve a la cola para el siguiente lote
        sin_respuesta = [i for n in lote if n['clave'] not in {x['clave'] for x in limpios} for i in n['ids']]
        if sin_respuesta:
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': sin_respuesta, 'p_estado': 'nuevo', 'p_motivo': None})
        r = sb.rpc('guardar_clasificacion', {'p_cliente': sb.cliente, 'p_resultados': limpios, 'p_modelo': uso['modelo'],
                                             'p_prompt_version': version, 'p_uso': uso})
        log(f'Lote de {len(lote)} ({len(ids)} noticias): {r} · tokens {uso["tokens_entrada"]}+{uso["tokens_salida"]}')
        total['lotes'] += 1
        total['noticias'] += len(ids)
        for k in ('tokens_entrada', 'tokens_salida', 'costo_usd'):
            total[k] += uso[k]
        if len(lote) < LOTE:
            break
    log(f'Terminado: {total}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
