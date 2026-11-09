#!/usr/bin/env python3
"""Recolector del Vigilante AVIA: lee las fuentes SIN IA y guarda en Supabase solo lo nuevo.

Cada vez que se ejecuta (cron cada 5 minutos):
  1. Pide a Supabase las fuentes activas y cuáles toca leer ya (según su frecuencia).
  2. Lee cada una según su método: RSS, Google News, GDELT, página web o Apify.
     - Página web: si no cambió desde la última vez (misma huella), no hace nada.
     - Apify: solo si queda saldo del tope mensual (parámetro apify_tope_usd_mes).
  3. Manda lo leído a vigilante.guardar_comprobacion(): la base descarta lo repetido, puntúa
     cada noticia y deja para AVIA solo las que pasan el filtro.
  4. Hace las búsquedas extra que AVIA dejó en la cola (vigilante.busquedas).

No usa IA y no gasta tokens. Solo usa la biblioteca estándar de Python 3.9+.

Uso:
  recolector.py                     # lo normal (cron)
  recolector.py --prueba            # lee y muestra lo que guardaría, sin escribir nada
  recolector.py --fuente CODIGO     # solo esa fuente, aunque no le toque
  recolector.py --todas             # todas las fuentes, aunque no les toque

Cron:  */5 * * * * /usr/bin/python3 /root/avia/recolector.py >> /var/log/avia-recolector.log 2>&1

Variables (en /etc/avia/supabase.env o en el archivo de AVIA_SUPABASE_ENV; NUNCA en Git):
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE=orbita-bolivia
  APIFY_TOKEN            (opcional: sin él, las fuentes de Apify quedan en aviso)
  APIFY_ACTOR_BUSQUEDA   (opcional: actor para las búsquedas que AVIA pide «por Apify»)
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import email.utils
import gzip
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from html.parser import HTMLParser

UA = 'Mozilla/5.0 (compatible; AVIA-Vigilante/1.0; recolector)'
TIMEOUT = 25
MAX_ITEMS = 50
HILOS = 6
VERSION = '1.0.0'


# ───────────────────────── configuración ─────────────────────────
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
                    k = k.replace('export ', '').strip()
                    os.environ.setdefault(k, v.strip().strip('"').strip("'"))
            return


def log(msg: str) -> None:
    print(f'{datetime.now(timezone.utc).isoformat(timespec="seconds")} {msg}', flush=True)


# ───────────────────────── Supabase ─────────────────────────
class Supabase:
    def __init__(self) -> None:
        self.url = os.environ['SUPABASE_URL'].rstrip('/')
        self.key = os.environ['SUPABASE_SERVICE_ROLE_KEY']
        self.cliente = os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia')

    def rpc(self, fn: str, args: dict) -> object:
        cab = {'apikey': self.key, 'Content-Type': 'application/json', 'Content-Profile': 'vigilante',
               'Accept-Profile': 'vigilante'}
        # las claves nuevas (sb_secret_…) van solo en «apikey»; las antiguas (JWT) también en Authorization
        if not self.key.startswith('sb_'):
            cab['Authorization'] = f'Bearer {self.key}'
        req = urllib.request.Request(f'{self.url}/rest/v1/rpc/{fn}', data=json.dumps(args).encode(), headers=cab, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                cuerpo = r.read()
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'Supabase {fn}: HTTP {e.code} {e.read()[:300].decode(errors="replace")}') from None
        return json.loads(cuerpo) if cuerpo else None


# ───────────────────────── lectura de la red ─────────────────────────
def descargar(url: str, *, datos: bytes | None = None, cabeceras: dict | None = None, timeout: int = TIMEOUT) -> tuple[int, bytes, str]:
    cab = {'User-Agent': UA, 'Accept': '*/*', 'Accept-Encoding': 'gzip', 'Accept-Language': 'es-BO,es;q=0.9'}
    cab.update(cabeceras or {})
    req = urllib.request.Request(url, data=datos, headers=cab, method='POST' if datos is not None else 'GET')
    with urllib.request.urlopen(req, timeout=timeout) as r:
        cuerpo = r.read()
        if r.headers.get('Content-Encoding') == 'gzip':
            cuerpo = gzip.decompress(cuerpo)
        return r.status, cuerpo, r.headers.get('Content-Type', '')


def sin_html(t: str | None) -> str:
    t = re.sub(r'<(script|style)[^>]*>.*?</\1>', ' ', t or '', flags=re.S | re.I)
    t = re.sub(r'<[^>]+>', ' ', t)
    return re.sub(r'\s+', ' ', html.unescape(t)).strip()


def fecha_iso(t: str | None) -> str | None:
    if not t:
        return None
    t = t.strip()
    try:
        return email.utils.parsedate_to_datetime(t).isoformat()
    except (TypeError, ValueError):
        pass
    m = re.match(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$', t)  # GDELT
    if m:
        return datetime(*map(int, m.groups()), tzinfo=timezone.utc).isoformat()
    try:
        return datetime.fromisoformat(t.replace('Z', '+00:00')).isoformat()
    except ValueError:
        return None


def leer_feed(cuerpo: bytes) -> list[dict]:
    """RSS 2.0 o Atom → [{titulo, url, resumen, publicado_en}]"""
    raiz = ET.fromstring(cuerpo)
    items = []
    for el in raiz.iter():
        nombre = el.tag.split('}')[-1]
        if nombre not in ('item', 'entry'):
            continue
        campos = {c.tag.split('}')[-1]: c for c in el}
        titulo = sin_html(campos['title'].text if 'title' in campos else '')
        enlace = ''
        if 'link' in campos:
            enlace = (campos['link'].text or campos['link'].get('href') or '').strip()
        resumen = ''
        for k in ('description', 'summary', 'content'):
            if k in campos and campos[k].text:
                resumen = sin_html(campos[k].text)
                break
        fecha = None
        for k in ('pubDate', 'published', 'updated', 'date'):
            if k in campos and campos[k].text:
                fecha = fecha_iso(campos[k].text)
                break
        if titulo and enlace:
            items.append({'titulo': titulo, 'url': enlace, 'resumen': resumen[:1500], 'publicado_en': fecha})
    return items[:MAX_ITEMS]


class Enlaces(HTMLParser):
    """Saca los enlaces con texto de una página (titulares) y su texto visible."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.enlaces: list[tuple[str, str]] = []
        self.texto: list[str] = []
        self._href: str | None = None
        self._buf: list[str] = []
        self._omitir = 0
        self.titulo = ''
        self._en_title = False

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'noscript'):
            self._omitir += 1
        elif tag == 'a':
            self._href = dict(attrs).get('href')
            self._buf = []
        elif tag == 'title':
            self._en_title = True

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'noscript') and self._omitir:
            self._omitir -= 1
        elif tag == 'a' and self._href:
            self.enlaces.append((self._href, re.sub(r'\s+', ' ', ''.join(self._buf)).strip()))
            self._href = None
        elif tag == 'title':
            self._en_title = False

    def handle_data(self, data):
        if self._omitir:
            return
        if self._en_title:
            self.titulo += data
        self.texto.append(data)
        if self._href is not None:
            self._buf.append(data)


def leer_pagina(url: str, huella_anterior: str | None) -> tuple[list[dict], str, str]:
    """Devuelve (items, huella, info). Si la página no cambió, items = []."""
    _, cuerpo, tipo = descargar(url)
    cod = 'utf-8'
    m = re.search(r'charset=([\w-]+)', tipo or '')
    if m:
        cod = m.group(1)
    texto_html = cuerpo.decode(cod, errors='replace')
    p = Enlaces()
    p.feed(texto_html)
    visible = re.sub(r'\s+', ' ', ' '.join(p.texto)).strip()
    huella = hashlib.sha256(visible.encode()).hexdigest()[:32]
    if huella_anterior and huella == huella_anterior:
        return [], huella, 'Sin cambios desde la última lectura'
    base = urllib.parse.urlparse(url)
    vistos, items = set(), []
    for href, txt in p.enlaces:
        if len(txt) < 25 or not href or href.startswith(('#', 'javascript:', 'mailto:')):
            continue
        absoluto = urllib.parse.urljoin(url, href)
        u = urllib.parse.urlparse(absoluto)
        if u.netloc.replace('www.', '') != base.netloc.replace('www.', '') or absoluto in vistos:
            continue
        vistos.add(absoluto)
        items.append({'titulo': txt[:300], 'url': absoluto})
    # una página sin titulares enlazados (p. ej. una tabla de avisos): la página entera es la novedad
    if not items:
        items = [{'titulo': (sin_html(p.titulo) or url)[:300], 'url': f'{url}#h{huella[:12]}', 'resumen': visible[:1500]}]
    return items[:MAX_ITEMS], huella, f'Página cambiada: {len(items)} enlaces'


def palabras(f: dict) -> list[str]:
    pc = f.get('palabras_clave') or []
    return [str(x).strip() for x in pc if str(x).strip()]


def consulta_de(f: dict) -> str:
    if f.get('query'):
        return f['query']
    pc = palabras(f)
    if pc:
        return ' OR '.join(f'"{x}"' if ' ' in x else x for x in pc[:8])
    return f.get('que_buscar') or f['nombre']


def url_google_news(consulta: str, cfg: dict, ventana: str = '1d') -> str:
    hl, gl = cfg.get('hl') or 'es-419', cfg.get('gl') or 'BO'
    q = urllib.parse.quote(f'{consulta} when:{ventana}')
    return f'https://news.google.com/rss/search?q={q}&hl={hl}&gl={gl}&ceid={gl}:{hl}'


def url_gdelt(consulta: str, cfg: dict, ventana: str = '1d') -> str:
    q = consulta if 'sourcecountry' in consulta or cfg.get('sin_pais') else f'({consulta}) sourcecountry:BL'
    return ('https://api.gdeltproject.org/api/v2/doc/doc?' +
            urllib.parse.urlencode({'query': q, 'mode': 'artlist', 'format': 'json', 'maxrecords': MAX_ITEMS,
                                    'timespan': ventana, 'sort': 'datedesc'}))


def leer_gdelt(url: str) -> list[dict]:
    _, cuerpo, _ = descargar(url)
    try:
        datos = json.loads(cuerpo or b'{}')
    except json.JSONDecodeError:
        raise RuntimeError(f'GDELT no devolvió JSON: {cuerpo[:120]!r}') from None
    return [{'titulo': a.get('title', '').strip(), 'url': a.get('url'), 'publicado_en': fecha_iso(a.get('seendate')),
             'extra': {'dominio': a.get('domain'), 'idioma': a.get('language')}}
            for a in datos.get('articles', []) if a.get('title') and a.get('url')][:MAX_ITEMS]


# ───────────────────────── Apify ─────────────────────────
def apify(actor: str, entrada: dict) -> tuple[list[dict], float]:
    token = os.environ.get('APIFY_TOKEN')
    if not token:
        raise RuntimeError('Falta APIFY_TOKEN en el archivo de variables')
    actor_id = actor.replace('/', '~')
    cab = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}
    _, cuerpo, _ = descargar(f'https://api.apify.com/v2/acts/{actor_id}/runs?waitForFinish=240',
                             datos=json.dumps(entrada).encode(), cabeceras=cab, timeout=270)
    run = json.loads(cuerpo)['data']
    costo = float(run.get('usageTotalUsd') or 0)
    if run.get('status') != 'SUCCEEDED':
        raise RuntimeError(f'Apify terminó en {run.get("status")} (coste USD {costo:.3f})')
    _, cuerpo, _ = descargar(f'https://api.apify.com/v2/datasets/{run["defaultDatasetId"]}/items?clean=true&limit={MAX_ITEMS}',
                             cabeceras={'Authorization': f'Bearer {token}'})
    items = []
    for x in json.loads(cuerpo):
        meta = x.get('metadata') or {}
        texto = x.get('text') or x.get('description') or x.get('caption') or meta.get('description') or ''
        titulo = x.get('title') or meta.get('title') or texto[:140]
        url = x.get('url') or x.get('link') or x.get('postUrl') or x.get('inputUrl')
        if titulo and url:
            items.append({'titulo': str(titulo).strip()[:300], 'url': url, 'resumen': str(texto)[:1500],
                          'publicado_en': fecha_iso(str(x.get('date') or x.get('publishedAt') or x.get('timestamp') or '') or None)})
    return items, costo


# ───────────────────────── una fuente ─────────────────────────
def leer_fuente(f: dict, sb: Supabase | None, apify_saldo: float) -> dict:
    """Devuelve {estado, info, items, huella, costo}. No escribe en la base."""
    metodo, url, cfg = f['metodo'], f['url'], f.get('config') or {}
    if metodo == 'rss':
        _, cuerpo, _ = descargar(url)
        items = leer_feed(cuerpo)
        return {'estado': 'OK' if items else 'WARN', 'info': f'{len(items)} entradas' if items else 'El RSS no tiene entradas', 'items': items}
    if metodo == 'google_news_rss':
        u = url if 'news.google.com/rss' in url else url_google_news(consulta_de(f), cfg)
        _, cuerpo, _ = descargar(u)
        items = leer_feed(cuerpo)
        return {'estado': 'OK', 'info': f'{len(items)} noticias en Google News', 'items': items}
    if metodo == 'gdelt':
        u = url if 'api.gdeltproject.org' in url and 'format=json' in url else url_gdelt(consulta_de(f), cfg)
        items = leer_gdelt(u)
        return {'estado': 'OK', 'info': f'{len(items)} artículos en GDELT', 'items': items}
    if metodo == 'http_html':
        items, huella, info = leer_pagina(url, f.get('huella'))
        return {'estado': 'OK', 'info': info, 'items': items, 'huella': huella}
    if metodo == 'apify':
        actor = f.get('apify_actor')
        if not actor:
            return {'estado': 'WARN', 'info': 'Falta el actor de Apify en la configuración de la fuente', 'items': []}
        if apify_saldo <= 0:
            return {'estado': 'WARN', 'info': 'Apify desactivado o sin saldo este mes (apify_tope_usd_mes)', 'items': []}
        entrada = f.get('apify_input') or {'startUrls': [{'url': url}]}
        items, costo = apify(actor, entrada)
        return {'estado': 'OK', 'info': f'{len(items)} resultados de Apify (USD {costo:.3f})', 'items': items, 'costo': costo}
    return {'estado': None, 'info': f'Método «{metodo}»: no lo lee el recolector', 'items': []}


def procesar_fuente(f: dict, sb: Supabase, prueba: bool, apify_saldo: float, ejecucion: str) -> str:
    t0 = time.time()
    try:
        r = leer_fuente(f, sb, apify_saldo)
    except urllib.error.HTTPError as e:
        r = {'estado': 'CRIT', 'info': f'HTTP {e.code} al leer {f["url"]}', 'items': []}
    except Exception as e:  # noqa: BLE001 — cualquier fallo de lectura es un CRIT de la fuente
        r = {'estado': 'CRIT', 'info': f'{type(e).__name__}: {str(e)[:200]}', 'items': []}
    seg = time.time() - t0
    if r['estado'] is None:
        return f'{f["codigo"]}: {r["info"]}'
    if prueba:
        muestra = '; '.join(i['titulo'][:60] for i in r['items'][:3])
        return f'{f["codigo"]} [{r["estado"]}] {r["info"]} ({seg:.1f}s) · {muestra}'
    res = sb.rpc('guardar_comprobacion', {'p_cliente': sb.cliente, 'p_codigo': f['codigo'], 'p_estado': r['estado'],
                                          'p_info': r['info'], 'p_items': r['items'], 'p_huella': r.get('huella'),
                                          'p_ejecucion': ejecucion})
    if r.get('costo'):
        sb.rpc('registrar_log', {'p_cliente': sb.cliente, 'p_proceso': 'apify', 'p_nivel': 'info',
                                 'p_mensaje': f'Apify en {f["codigo"]}', 'p_detalle': {'actor': f.get('apify_actor')},
                                 'p_costo_usd': r['costo'], 'p_codigo_fuente': f['codigo']})
    return f'{f["codigo"]} [{r["estado"]}] {r["info"]} → {res} ({seg:.1f}s)'


# ───────────────────────── búsquedas pedidas por AVIA ─────────────────────────
def procesar_busqueda(b: dict, sb: Supabase, apify_saldo: float, ejecucion: str) -> str:
    items, costo, ok, info = [], None, True, None
    try:
        if b['via'] == 'apify':
            actor = (b.get('parametros') or {}).get('apify_actor') or os.environ.get('APIFY_ACTOR_BUSQUEDA')
            if not actor:
                raise RuntimeError('Falta el actor de Apify (parámetro apify_actor o APIFY_ACTOR_BUSQUEDA)')
            if apify_saldo <= 0:
                raise RuntimeError('Apify desactivado o sin saldo este mes')
            entrada = (b.get('parametros') or {}).get('apify_input') or {'queries': b['consulta']}
            items, costo = apify(actor, entrada)
        else:
            ventana = f'{int((b.get("parametros") or {}).get("dias", 7))}d'
            _, cuerpo, _ = descargar(url_google_news(b['consulta'], b.get('parametros') or {}, ventana))
            items = leer_feed(cuerpo)
            try:
                items += leer_gdelt(url_gdelt(b['consulta'], b.get('parametros') or {}, ventana))
            except Exception as e:  # noqa: BLE001 — GDELT es un extra
                log(f'  GDELT falló en la búsqueda {b["id"]}: {e}')
    except Exception as e:  # noqa: BLE001
        ok, info = False, f'{type(e).__name__}: {str(e)[:200]}'
    res = sb.rpc('guardar_busqueda', {'p_cliente': sb.cliente, 'p_id': b['id'], 'p_ok': ok, 'p_info': info,
                                      'p_items': items[:MAX_ITEMS * 2], 'p_costo_usd': costo, 'p_ejecucion': ejecucion})
    if costo:
        sb.rpc('registrar_log', {'p_cliente': sb.cliente, 'p_proceso': 'apify', 'p_nivel': 'info',
                                 'p_mensaje': f'Apify en la búsqueda {b["id"]}', 'p_detalle': {'consulta': b['consulta']},
                                 'p_costo_usd': costo, 'p_codigo_fuente': None})
    return f'búsqueda {b["id"]} «{b["consulta"]}» ({b["via"]}): ' + (f'{res}' if ok else f'falló: {info}')


# ───────────────────────── principal ─────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description='Recolector del Vigilante AVIA (sin IA)')
    ap.add_argument('--prueba', action='store_true', help='leer y mostrar, sin escribir en la base')
    ap.add_argument('--fuente', help='leer solo esta fuente (por su código), aunque no le toque')
    ap.add_argument('--todas', action='store_true', help='leer todas las fuentes activas, aunque no les toque')
    ap.add_argument('--sin-busquedas', action='store_true', help='no hacer las búsquedas pedidas por AVIA')
    a = ap.parse_args()

    cargar_env()
    for v in ('SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY'):
        if not os.environ.get(v):
            log(f'Falta {v}: revisa /etc/avia/supabase.env')
            return 2

    # una sola ejecución a la vez
    try:
        import fcntl
        candado = open('/tmp/avia-recolector.lock', 'w')
        fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log('Otra ejecución sigue en marcha: salgo')
        return 0
    except ImportError:
        pass

    sb = Supabase()
    ejecucion = f'recolector-{datetime.now(timezone.utc):%Y%m%dT%H%M%S}'
    lista = sb.rpc('fuentes_para_recolector', {'p_cliente': sb.cliente})
    fuentes = lista.get('fuentes', [])
    saldo = float(lista.get('apify_disponible_usd') or 0)
    if a.fuente:
        fuentes = [f for f in fuentes if f['codigo'] == a.fuente]
        if not fuentes:
            log(f'La fuente {a.fuente} no existe o no está activa')
            return 1
    elif not a.todas:
        fuentes = [f for f in fuentes if f.get('toca')]
    log(f'{ejecucion}: {len(fuentes)} fuentes por leer · Apify disponible USD {saldo:.2f}')

    with cf.ThreadPoolExecutor(max_workers=HILOS) as ex:
        # Apify va de una en una para no pasarse del tope
        normales = [f for f in fuentes if f['metodo'] != 'apify']
        for linea in ex.map(lambda f: procesar_fuente(f, sb, a.prueba, saldo, ejecucion), normales):
            log('  ' + linea)
    for f in (f for f in fuentes if f['metodo'] == 'apify'):
        log('  ' + procesar_fuente(f, sb, a.prueba, saldo, ejecucion))
        if not a.prueba:
            saldo = float(sb.rpc('fuentes_para_recolector', {'p_cliente': sb.cliente}).get('apify_disponible_usd') or 0)

    if not a.prueba and not a.sin_busquedas and not a.fuente:
        for b in sb.rpc('tomar_busquedas', {'p_cliente': sb.cliente, 'p_limite': 5}) or []:
            log('  ' + procesar_busqueda(b, sb, saldo, ejecucion))
    log(f'{ejecucion}: terminado')
    return 0


if __name__ == '__main__':
    sys.exit(main())
