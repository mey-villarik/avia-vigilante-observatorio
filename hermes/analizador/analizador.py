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
  5. Si guardó algo, pide a la base que componga eventos (vigilante.componer_eventos, migración 28).

Desde la migración 31, cada noticia llega con las señales abiertas que pueden hablar de lo mismo
(senales_relacionadas). Si el modelo ve que la noticia cambia una de ellas (nueva fecha, cancelación,
desvío, desmentido…), devuelve «cambio» y la base lo registra para la alerta del panel.

Desde la migración 37, las noticias de fuentes internacionales (OPS/OMS, CEPAL, BBC/Reuters/AP)
llegan con «internacional»: true y las señales nacionales que pueden tener que ver. El modelo dice
si afectan a Bolivia (impacto_bolivia: ámbitos, vía, nivel, plazo, señales que refuerza). Sin impacto
en Bolivia, la noticia se descarta aquí mismo; con impacto, la base lo guarda en la señal.

Desde la migración 48 (CP1 y CP2), los plazos se guardan siempre como fecha: si la fuente dice «quedan 12 días»,
la fecha se calcula aquí con el día de publicación (plazo_origen «calculado», que la base muestra como «pendiente
de verificar») y esa cuenta relativa se cambia por la fecha en el título y el resumen.

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
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

LOTE = 10           # 2026-11-26: con 15 la respuesta no cabía en 4000 tokens (ver clasificar_por_partes)
MAX_TOKENS = 8000   # máximo de salida de deepseek-chat (8K)
TIMEOUT = 180
AQUI = Path(__file__).resolve().parent
PROMPT = AQUI / 'prompt_clasificador.md'

NATURALEZAS = {'riesgo', 'oportunidad', 'mixta'}
CATEGORIAS = {'clima', 'salud', 'vial', 'seguridad', 'conectividad', 'eventos', 'financiamiento', 'normativa', 'mercados', 'economia'}
PRIORIDADES = {'alta', 'media', 'baja'}
CERTEZAS = ('confirmado', 'convocado', 'posible', 'rumor')
TAREAS = {'corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida'}
# migración 31: tipos de cambio en una señal que ya existía
# migración 37: impacto en Bolivia de lo que llega de fuentes internacionales
AMBITOS = {'turismo', 'salud', 'economia', 'clima', 'infraestructura'}
PLAZOS = {'inmediato', 'semanas', 'meses'}
CAMBIOS = {'fecha', 'plazo', 'cancelado', 'desviado', 'resuelto', 'agravado', 'atenuado', 'lugar', 'desmentido', 'confirmado', 'otro'}
FECHA = re.compile(r'^\d{4}-\d{2}-\d{2}$')
BOLIVIA = timezone(timedelta(hours=-4))
# CP1 (migración 48): los plazos se guardan como FECHA. «Quedan 12 días» se convierte aquí en fecha con la
# fecha de publicación de la noticia, y nunca se deja escrito en el título ni en el resumen: esa frase
# era verdad el día de la noticia y deja de serlo al día siguiente.
_NUM = {'un': 1, 'una': 1, 'uno': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6, 'siete': 7, 'ocho': 8,
        'nueve': 9, 'diez': 10, 'once': 11, 'doce': 12, 'trece': 13, 'catorce': 14, 'quince': 15, 'veinte': 20,
        'treinta': 30}
_N = r'(?P<n>\d{1,3}|' + '|'.join(_NUM) + r')'
_RESTO = r'\s+(?:solo\s+|s[oó]lo\s+|apenas\s+|unos?\s+)?' + _N + r'\s+(?P<unidad>d[ií]as?|semanas?)(?:\s+h[aá]biles)?'
# plazos: «quedan 12 días», «cierra en 5 días», «plazo de 10 días»
PLAZO_REL = re.compile(r'\b(?P<verbo>quedan|queda|faltan|falta|restan|resta|plazo\s+de|'
                       r'(?:cierra|vence|termina|finaliza|concluye|caduca)\s+en)' + _RESTO, re.I)
# cualquier cuenta relativa que hay que cambiar por la fecha en el texto (también «dentro de dos semanas»)
RELATIVO = re.compile(r'\b(?P<verbo>quedan|queda|faltan|falta|restan|resta|plazo\s+de|'
                      r'(?:cierra|vence|termina|finaliza|concluye|caduca)\s+en|dentro\s+de|en\s+los\s+pr[oó]ximos)' + _RESTO, re.I)
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


class RespuestaRota(Exception):
    """El modelo contestó, pero su JSON viene cortado o mal formado. Lleva el uso: esos tokens ya se pagaron."""

    def __init__(self, motivo: str, uso: dict) -> None:
        super().__init__(motivo)
        self.uso = uso


def sumar_uso(*usos: dict) -> dict:
    t = {'modelo': next((u['modelo'] for u in usos if u.get('modelo')), None),
         'tokens_entrada': 0, 'tokens_salida': 0, 'costo_usd': 0.0}
    for u in usos:
        for k in ('tokens_entrada', 'tokens_salida', 'costo_usd'):
            t[k] += u.get(k) or 0
    t['costo_usd'] = round(t['costo_usd'], 6)
    return t


def llamar_modelo(sistema: str, lote: list[dict]) -> tuple[list[dict], dict]:
    base = os.environ.get('LLM_BASE_URL', 'https://api.deepseek.com').rstrip('/')
    clave = os.environ.get('LLM_API_KEY') or os.environ.get('DEEPSEEK_API_KEY')
    if not clave:
        raise RuntimeError('Falta LLM_API_KEY (o DEEPSEEK_API_KEY) en el archivo de variables')
    modelo = os.environ.get('LLM_MODEL', 'deepseek-chat')
    # al modelo solo le llega lo necesario para clasificar
    entrada = [{k: n.get(k) for k in ('clave', 'titulo', 'texto', 'fuente', 'fuente_tipo', 'fuentes_que_coinciden', 'publicado_en',
                                      'territorios', 'oportunidad_candidata', 'es_actualizacion', 'senal_existente',
                                      'senales_relacionadas', 'internacional', 'senales_nacionales')}
               for n in lote]
    # sin claves vacías: las noticias nacionales no llevan «internacional» ni «senales_nacionales»
    entrada = [{k: v for k, v in n.items() if v is not None} for n in entrada]
    r = post(f'{base}/chat/completions', {
        'model': modelo, 'temperature': 0, 'max_tokens': MAX_TOKENS,
        'response_format': {'type': 'json_object'},
        'messages': [{'role': 'system', 'content': sistema},
                     {'role': 'user', 'content': json.dumps({'noticias': entrada}, ensure_ascii=False)}],
    }, {'Authorization': f'Bearer {clave}'}, timeout=TIMEOUT)
    uso = r.get('usage') or {}
    te, ts = int(uso.get('prompt_tokens') or 0), int(uso.get('completion_tokens') or 0)
    pe, ps = float(os.environ.get('LLM_PRECIO_ENTRADA') or 0), float(os.environ.get('LLM_PRECIO_SALIDA') or 0)
    uso = {'modelo': modelo, 'tokens_entrada': te, 'tokens_salida': ts, 'costo_usd': round((te * pe + ts * ps) / 1e6, 6)}
    eleccion = r['choices'][0]
    contenido = eleccion['message']['content'] or ''
    # 2026-11-26: con 15 noticias la respuesta pasaba de 4000 tokens y llegaba cortada a mitad de una
    # cadena («Unterminated string»). El lote volvía entero a la cola y fallaba igual en cada ronda.
    if eleccion.get('finish_reason') == 'length':
        raise RespuestaRota(f'respuesta cortada por el límite de {MAX_TOKENS} tokens', uso)
    try:
        datos = json.loads(re.sub(r'^```(json)?|```$', '', contenido.strip()).strip())
    except json.JSONDecodeError as e:
        raise RespuestaRota(f'JSON mal formado: {e}', uso) from None
    return (datos.get('resultados') if isinstance(datos, dict) else datos) or [], uso


def clasificar_por_partes(sistema: str, lote: list[dict]) -> tuple[list[dict], dict, list[dict]]:
    """Llama al modelo con el lote; si la respuesta llega rota, lo parte en dos y lo intenta con cada mitad.
    Devuelve (resultados, uso total, noticias que ni solas tuvieron una respuesta válida)."""
    try:
        res, uso = llamar_modelo(sistema, lote)
        return res, uso, []
    except RespuestaRota as e:
        if len(lote) == 1:
            log(f'La noticia {lote[0]["clave"]} no tiene respuesta válida ni sola ({e})')
            return [], e.uso, lote
        mitad = len(lote) // 2
        log(f'Respuesta rota con {len(lote)} noticias ({e}): pruebo con {mitad} y {len(lote) - mitad}')
        r1, u1, s1 = clasificar_por_partes(sistema, lote[:mitad])
        r2, u2, s2 = clasificar_por_partes(sistema, lote[mitad:])
        return r1 + r2, sumar_uso(e.uso, u1, u2), s1 + s2


def senales_del_lote(lote: list[dict]) -> dict[int, set[str]]:
    """Códigos de señal que se mandaron con cada noticia: el modelo solo puede decir que cambia una de esas."""
    r: dict[int, set[str]] = {}
    for n in lote:
        cods = {s.get('codigo') for s in (n.get('senales_relacionadas') or []) if isinstance(s, dict)}
        if isinstance(n.get('senal_existente'), dict):
            cods.add(n['senal_existente'].get('codigo'))
        r[n['clave']] = {c for c in cods if c}
    return r


def nacionales_del_lote(lote: list[dict]) -> dict[int, set[str]]:
    """Noticias internacionales del lote y las señales nacionales que se le mandaron a cada una (migración 37)."""
    return {n['clave']: {s.get('codigo') for s in (n.get('senales_nacionales') or []) if isinstance(s, dict) and s.get('codigo')}
            for n in lote if n.get('internacional')}


def impacto_bolivia(ib: object, permitidas: set[str]) -> dict | None:
    """Valida el impacto en Bolivia de una noticia internacional. None = sin impacto (o sin decir por qué)."""
    if not isinstance(ib, dict) or ib.get('hay_impacto') is not True:
        return None
    via = str(ib.get('via') or '').strip()
    ambitos = [a for a in (ib.get('ambitos') or []) if isinstance(a, str) and a.lower() in AMBITOS] if isinstance(ib.get('ambitos'), list) else []
    if not via or not ambitos:
        return None   # sin vía concreta no hay impacto demostrado
    ref = ib.get('refuerza') if isinstance(ib.get('refuerza'), list) else []
    return {'hay_impacto': True, 'ambitos': sorted({a.lower() for a in ambitos}), 'via': via[:400],
            'nivel': ib.get('nivel') if ib.get('nivel') in ('alto', 'medio', 'bajo') else 'bajo',
            'plazo': ib.get('plazo') if ib.get('plazo') in PLAZOS else None,
            'refuerza': [c for c in dict.fromkeys(ref) if c in permitidas]}


def _dia_publicacion(publicado: object) -> date | None:
    """Día de publicación de la noticia en Bolivia (lote_para_clasificar trae «publicado_en»)."""
    if not publicado:
        return None
    try:
        t = datetime.fromisoformat(str(publicado).replace('Z', '+00:00'))
    except ValueError:
        return None
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(BOLIVIA).date()


def _dias_relativos(m: re.Match) -> int:
    n = m.group('n').lower()
    n = int(n) if n.isdigit() else _NUM.get(n, 0)
    return n * 7 if m.group('unidad').lower().startswith('semana') else n


def _fecha_txt(d: date) -> str:
    return d.strftime('%d/%m/%Y')


def _sin_relativos(t: object, base: date) -> object:
    """Cambia cada cuenta relativa por su fecha: «quedan 12 días» → «hasta el 30/11/2026»,
    «cierra en 5 días» → «cierra el 23/11/2026», «dentro de dos semanas» → «el 02/12/2026»."""
    if not isinstance(t, str):
        return t

    def uno(m: re.Match) -> str:
        f = _fecha_txt(base + timedelta(days=_dias_relativos(m)))
        v = re.sub(r'\s+', ' ', m.group('verbo').lower())
        if v.endswith(' en'):
            r = f'{v[:-3]} el {f}'
        elif v in ('dentro de', 'en los próximos', 'en los proximos'):
            r = f'el {f}'
        elif v == 'plazo de':
            r = f'plazo hasta el {f}'
        else:
            r = f'hasta el {f}'
        inicio = m.start() == 0 or t[:m.start()].rstrip().endswith(('.', '!', '?', ':', '\n'))
        return r[0].upper() + r[1:] if inicio else r
    return RELATIVO.sub(uno, t)


def fijar_plazo(x: dict, publicado: object, hoy: date | None = None) -> dict:
    """CP1: deja en x una fecha de cierre absoluta y de dónde sale (plazo_origen 'texto' o 'calculado'),
    y cambia en el texto las cuentas relativas («quedan 12 días») por su fecha."""
    base = _dia_publicacion(publicado) or hoy or datetime.now(BOLIVIA).date()
    cita = str(x.get('plazo_cita') or '').strip()[:200]
    op = x.get('oportunidad') if isinstance(x.get('oportunidad'), dict) else {}
    textos = [cita, str(x.get('resumen') or ''), str(x.get('titulo') or ''), str(op.get('hecho') or '')]
    rel = next((m for t in textos if t for m in [PLAZO_REL.search(t)] if m), None)
    if rel:
        # nunca nos fiamos de la cuenta del modelo: fecha = día de publicación + N
        x['plazo_hasta'] = (base + timedelta(days=_dias_relativos(rel))).isoformat()
        x['plazo_origen'] = 'calculado'
        x['plazo_cita'] = cita if cita and PLAZO_REL.search(cita) else rel.group(0)
    elif isinstance(x.get('plazo_hasta'), str) and FECHA.match(x['plazo_hasta']):
        x['plazo_origen'] = 'texto'
        if cita:
            x['plazo_cita'] = cita
    else:
        x.pop('plazo_origen', None)
        x.pop('plazo_cita', None)
    for k in ('titulo', 'resumen', 'recomendacion'):
        if k in x:
            x[k] = _sin_relativos(x[k], base)
    if isinstance(x.get('oportunidad'), dict):
        for k in ('hecho', 'accion', 'interpretacion'):
            if k in x['oportunidad']:
                x['oportunidad'][k] = _sin_relativos(x['oportunidad'][k], base)
    return x


def limpiar(res: list, claves: set[int], senales: dict[int, set[str]] | None = None,
            internacionales: dict[int, set[str]] | None = None, publicados: dict[int, object] | None = None) -> list[dict]:
    """Solo claves del lote, valores permitidos y nada de procedencia."""
    senales = senales or {}
    internacionales = internacionales or {}
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
        # migración 37: una noticia internacional solo sigue si afecta a Bolivia y dice por qué vía
        if clave in internacionales:
            ib = impacto_bolivia(x.get('impacto_bolivia'), internacionales[clave])
            if ib is None:
                motivo = x.get('motivo') if not x['relevante'] and x.get('motivo') else 'sin impacto en Bolivia'
                ok.append({'clave': clave, 'relevante': False, 'motivo': motivo})
                continue
            x['impacto_bolivia'] = ib
        else:
            x.pop('impacto_bolivia', None)
        if x.get('naturaleza') not in NATURALEZAS:
            x.pop('naturaleza', None)
        if x.get('categoria') not in CATEGORIAS:
            x.pop('categoria', None)
        if x.get('prioridad') not in PRIORIDADES:
            x.pop('prioridad', None)
        for k in ('fecha_evento_inicio', 'fecha_evento_fin', 'plazo_hasta'):
            if not (isinstance(x.get(k), str) and FECHA.match(x[k])):
                x.pop(k, None)
        if x['relevante']:
            fijar_plazo(x, (publicados or {}).get(clave))
        if not isinstance(x.get('departamentos'), list):
            x.pop('departamentos', None)
        try:
            x['confianza'] = max(0.0, min(1.0, float(x['confianza']))) if 'confianza' in x else None
        except (TypeError, ValueError):
            x['confianza'] = None
        # mejora 4: impacto y probabilidad solo con motivo (la base los usa en vigilante.puntuaciones)
        imp = x.get('impacto')
        if not (isinstance(imp, dict) and imp.get('nivel') in ('alto', 'medio', 'bajo') and str(imp.get('motivo') or '').strip()):
            x.pop('impacto', None)
        pr = x.get('probabilidad')
        try:
            ok_pr = isinstance(pr, dict) and 0 <= float(pr.get('valor')) <= 1 and str(pr.get('justificacion') or '').strip()
        except (TypeError, ValueError):
            ok_pr = False
        if ok_pr:
            pr['valor'] = round(float(pr['valor']), 2)
        else:
            x.pop('probabilidad', None)
        # mejora 6: grado de certeza con motivo (la base lo comprueba en vigilante.certeza)
        ce = x.get('certeza')
        if not (isinstance(ce, dict) and ce.get('nivel') in CERTEZAS and str(ce.get('motivo') or '').strip()):
            x.pop('certeza', None)
        # mejora 7: qué falta saber (1 a 4 frases) y para quién; la base añade el resto en vigilante.recomendacion_segura
        fs = x.get('falta_saber')
        if isinstance(fs, list):
            x['falta_saber'] = [str(f).strip()[:200] for f in fs if isinstance(f, str) and f.strip()][:4]
        else:
            x.pop('falta_saber', None)
        if not (isinstance(x.get('para_quien'), str) and x['para_quien'].strip()):
            x.pop('para_quien', None)
        op = x.get('oportunidad')
        if not (isinstance(op, dict) and op.get('hecho') and op.get('tipo')):
            x.pop('oportunidad', None)
        # migración 31: la noticia cambia una señal que ya existía (solo una de las que se le mandaron)
        ca = x.get('cambio')
        if isinstance(ca, dict) and str(ca.get('ahora') or '').strip() and ca.get('senal') in senales.get(clave, set()):
            x['cambio'] = {'senal': ca['senal'], 'tipo': ca.get('tipo') if ca.get('tipo') in CAMBIOS else 'otro',
                           'antes': str(ca.get('antes') or '').strip()[:400] or None, 'ahora': str(ca['ahora']).strip()[:400],
                           'importancia': ca.get('importancia') if ca.get('importancia') in PRIORIDADES else None}
        else:
            x.pop('cambio', None)
        # migración 43: la noticia cuenta el mismo hecho que una señal que ya existe (solo una de las que se le mandaron)
        ms = x.get('misma_senal')
        if isinstance(ms, str) and ms.strip() in senales.get(clave, set()) and not isinstance(x.get('cambio'), dict):
            x['misma_senal'] = ms.strip()
        else:
            x.pop('misma_senal', None)
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
            res, uso, sueltas = clasificar_por_partes(sistema, lote)
        except Exception as e:  # noqa: BLE001 — si el modelo falla (saldo, red…), las noticias vuelven a la cola
            log(f'El modelo falló ({type(e).__name__}: {str(e)[:200]}): devuelvo {len(ids)} noticias a la cola')
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': ids, 'p_estado': 'nuevo', 'p_motivo': None})
            sb.rpc('registrar_log', {'p_cliente': sb.cliente, 'p_proceso': 'clasificador', 'p_nivel': 'error',
                                     'p_mensaje': f'Fallo del modelo: {str(e)[:300]}', 'p_detalle': None,
                                     'p_costo_usd': None, 'p_codigo_fuente': None})
            return 1
        limpios = limpiar(res, {n['clave'] for n in lote}, senales_del_lote(lote), nacionales_del_lote(lote),
                          {n['clave']: n.get('publicado_en') for n in lote})
        # una noticia que ni sola tiene respuesta válida no puede volver a la cola: la bloquearía para siempre
        if sueltas and not a.prueba:
            ids_sueltas = [i for n in sueltas for i in n['ids']]
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': ids_sueltas, 'p_estado': 'descartado',
                                       'p_motivo': 'el modelo no devolvió una respuesta válida para esta noticia'})
            sb.rpc('registrar_log', {'p_cliente': sb.cliente, 'p_proceso': 'clasificador', 'p_nivel': 'warn',
                                     'p_mensaje': f'{len(sueltas)} noticia(s) sin respuesta válida del modelo: descartadas',
                                     'p_detalle': {'claves': [n['clave'] for n in sueltas]},
                                     'p_costo_usd': None, 'p_codigo_fuente': None})
        if a.prueba:
            print(json.dumps({'lote': lote, 'resultado': limpios, 'uso': uso}, ensure_ascii=False, indent=2))
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': ids, 'p_estado': 'nuevo', 'p_motivo': None})
            return 0
        # lo que el modelo no devolvió vuelve a la cola para el siguiente lote
        claves_sueltas = {n['clave'] for n in sueltas}
        sin_respuesta = [i for n in lote if n['clave'] not in {x['clave'] for x in limpios} and n['clave'] not in claves_sueltas
                         for i in n['ids']]
        if sin_respuesta:
            sb.rpc('marcar_noticias', {'p_cliente': sb.cliente, 'p_ids': sin_respuesta, 'p_estado': 'nuevo', 'p_motivo': None})
        intl = [x for x in limpios if x['clave'] in nacionales_del_lote(lote)]
        if intl:
            log(f'Internacionales: {len(intl)} en el lote, {sum(1 for x in intl if x.get("impacto_bolivia"))} con impacto en Bolivia (migración 37)')
        cambios = sum(1 for x in limpios if x.get('cambio'))
        if cambios:
            log(f'El clasificador ve {cambios} cambio(s) en señales que ya existían (migración 31)')
        if not limpios:
            log(f'Lote de {len(lote)}: ninguna respuesta válida del modelo, nada que guardar')
            continue
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
    # migración 28: con señales nuevas, la base mira si coinciden con otras (eventos compuestos).
    # pg_cron también lo hace cada 5 minutos; aquí solo se adelanta. Sin IA: Hermes los interpreta después.
    if total['lotes'] and not a.prueba:
        try:
            log(f'Eventos compuestos: {sb.rpc("componer_eventos", {"p_cliente": sb.cliente})}')
        except Exception as e:  # noqa: BLE001 — si falta el 28 o falla, la clasificación ya está guardada
            log(f'No se pudieron componer eventos ({str(e)[:200]}); pg_cron lo reintentará')
    return 0


if __name__ == '__main__':
    sys.exit(main())
