#!/usr/bin/env python3
"""Genera vigilante.json DESDE Supabase (al revés que antes: ya no lo escribe Hermes).

La web con sesión ya lee la base directamente (vigilante_bd). Este archivo solo hace falta para
lo que todavía espera el fichero: la web antigua, /data/vigilante.json en nginx o el almacenamiento
privado de Supabase. Se genera con vigilante.vigilante_json(cliente) y solo se escribe si cambió.

Uso:
  exportar_vigilante_json.py --archivo /var/www/data/vigilante.json      # escribir en disco (nginx)
  exportar_vigilante_json.py --almacenamiento                            # subir a Supabase Storage (vigilante/<cliente>/vigilante.json)
  exportar_vigilante_json.py --archivo ... --almacenamiento              # las dos cosas

Variables: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE (en /etc/avia/supabase.env).
Sustituye a integraciones/hermes-web/subir_vigilante_json.sh: ese script llevaba el archivo de Hermes
a la base; si sigue en el cron, quítalo (pisaría lo que guardan el recolector y el analizador).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone


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


def peticion(url: str, datos: bytes, cab: dict) -> bytes:
    req = urllib.request.Request(url, data=datos, headers=cab, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'HTTP {e.code}: {e.read()[:300].decode(errors="replace")}') from None


def main() -> int:
    ap = argparse.ArgumentParser(description='Genera vigilante.json desde Supabase')
    ap.add_argument('--archivo', help='ruta donde escribir el archivo')
    ap.add_argument('--almacenamiento', action='store_true', help='subirlo a Supabase Storage (bucket vigilante)')
    a = ap.parse_args()
    if not a.archivo and not a.almacenamiento:
        ap.error('indica --archivo, --almacenamiento o los dos')

    cargar_env()
    url, key = os.environ['SUPABASE_URL'].rstrip('/'), os.environ['SUPABASE_SERVICE_ROLE_KEY']
    cliente = os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia')
    cab = {'apikey': key, 'Content-Type': 'application/json'}
    if not key.startswith('sb_'):
        cab['Authorization'] = f'Bearer {key}'

    datos = json.loads(peticion(f'{url}/rest/v1/rpc/vigilante_json', json.dumps({'p_cliente': cliente}).encode(),
                                {**cab, 'Content-Profile': 'vigilante', 'Accept-Profile': 'vigilante'}))
    # la huella no cuenta la hora de generación: si nada cambió, no se escribe ni se sube
    huella = hashlib.sha256(json.dumps({k: v for k, v in datos.items() if k != 'generado'}, sort_keys=True).encode()).hexdigest()
    marca = f'/var/tmp/avia-exportar-{cliente}.sha256'
    if os.path.isfile(marca) and open(marca).read().strip() == huella:
        return 0
    cuerpo = json.dumps(datos, ensure_ascii=False).encode()

    if a.archivo:
        carpeta = os.path.dirname(os.path.abspath(a.archivo))
        with tempfile.NamedTemporaryFile('wb', dir=carpeta, delete=False) as t:
            t.write(cuerpo)
        os.chmod(t.name, 0o644)
        os.replace(t.name, a.archivo)  # atómico: la web nunca lee un archivo a medio escribir
    if a.almacenamiento:
        peticion(f'{url}/storage/v1/object/vigilante/{cliente}/vigilante.json', cuerpo,
                 {**cab, 'Cache-Control': 'no-cache', 'x-upsert': 'true'})
    with open(marca, 'w') as f:
        f.write(huella)
    print(f'{datetime.now(timezone.utc).isoformat(timespec="seconds")} vigilante.json de {cliente}: '
          f'{len(datos.get("senales", []))} señales, {len(datos.get("fuentes", []))} fuentes, '
          f'{len(datos.get("oportunidades", []))} oportunidades', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
