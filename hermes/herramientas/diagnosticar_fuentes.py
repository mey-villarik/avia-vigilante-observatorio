#!/usr/bin/env python3
"""Diagnóstico de fuentes que fallan: ¿problema pasajero o definitivo?

Ejecutar EN EL VPS (es desde donde lee el recolector):
  python3 diagnosticar_fuentes.py                 # las direcciones conocidas de Gaceta, Conoce Bolivia y SENAMHI
  python3 diagnosticar_fuentes.py URL [URL ...]   # otras direcciones
  python3 diagnosticar_fuentes.py --veces 3       # repetir cada prueba (para ver si es intermitente)

Para cada dirección comprueba, por pasos:
  1. DNS: ¿el dominio existe?        → si falla: DEFINITIVO (dominio dado de baja o cambiado)
  2. Conexión TCP al puerto           → si falla: servidor caído o bloquea la IP del VPS
  3. Respuesta HTTP (espera 90 s)     → código, segundos que tardó, tamaño, a dónde redirige
Solo usa la biblioteca estándar de Python.
"""
from __future__ import annotations

import argparse
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

UA = 'Mozilla/5.0 (compatible; AVIA-Vigilante/1.0; recolector)'
CONOCIDAS = [
    # Gaceta Oficial (solo http; https suele no responder)
    'http://www.gacetaoficialdebolivia.gob.bo/normas/listadofec',
    'http://www.gacetaoficialdebolivia.gob.bo/normas/buscar',
    'http://www.gacetaoficialdebolivia.gob.bo/',
    'https://www.gacetaoficialdebolivia.gob.bo/',
    # Conoce Bolivia: dominio antiguo y el nuevo (Ministerio de Desarrollo Productivo)
    'https://conocebolivia.turismoyculturas.gob.bo/',
    'https://conocebolivia.produccion.gob.bo/',
    'https://conocebolivia.produccion.gob.bo/feed/',
    'https://www.turismoyculturas.gob.bo/',
    # SENAMHI directo (sin Apify)
    'https://senamhi.gob.bo/alertas3.php',
    'https://senamhi.gob.bo/alertasanteriores1.php',
    'https://noticias.senamhi.gob.bo/home/',
]


def probar(url: str, espera: int) -> str:
    u = urllib.parse.urlparse(url)
    puerto = u.port or (443 if u.scheme == 'https' else 80)
    t0 = time.time()
    try:
        ips = sorted({a[4][0] for a in socket.getaddrinfo(u.hostname, puerto, proto=socket.IPPROTO_TCP)})
    except socket.gaierror as e:
        return f'DNS FALLA ({e.strerror}) → el dominio no existe: DEFINITIVO'
    try:
        with socket.create_connection((u.hostname, puerto), timeout=20):
            pass
    except OSError as e:
        return f'DNS ok {ips[:2]} · TCP {puerto} FALLA ({e.__class__.__name__}) → servidor caído o bloquea al VPS'
    tcp = time.time() - t0
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'es-BO,es;q=0.9'})
    t1 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=espera, context=ssl.create_default_context()) as r:
            cuerpo = r.read()
            final = r.geturl()
            red = f' · redirige a {final}' if final != url else ''
            return f'HTTP {r.status} en {time.time() - t1:.1f} s · {len(cuerpo) // 1024} KB{red} (TCP {tcp:.1f} s)'
    except urllib.error.HTTPError as e:
        return f'HTTP {e.code} en {time.time() - t1:.1f} s'
    except (TimeoutError, socket.timeout):
        return f'TCP ok pero NO RESPONDE en {espera} s → servidor lento: subir timeout_s o usar respaldo'
    except urllib.error.URLError as e:
        r = e.reason
        if isinstance(r, (TimeoutError, socket.timeout)):
            return f'TCP ok pero NO RESPONDE en {espera} s → servidor lento: subir timeout_s o usar respaldo'
        return f'FALLA {r.__class__.__name__}: {str(r)[:120]}'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('urls', nargs='*')
    ap.add_argument('--veces', type=int, default=1)
    ap.add_argument('--espera', type=int, default=90, help='segundos de espera de la respuesta HTTP')
    a = ap.parse_args()
    for url in a.urls or CONOCIDAS:
        print(url)
        for i in range(a.veces):
            print(f'  [{i + 1}] {probar(url, a.espera)}', flush=True)
            if i + 1 < a.veces:
                time.sleep(10)


if __name__ == '__main__':
    main()
