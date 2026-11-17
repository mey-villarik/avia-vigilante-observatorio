#!/usr/bin/env python3
"""Batería de pruebas de AVIA (mejora 10 de la PoC, documento del revisor).

Hace las 20 preguntas de bateria.json al chat de avia-api, comprueba lo que se puede comprobar con
reglas (que aparezcan los bloques, que no afirme una ruta como operativa, que cite la hora de los datos...)
y escribe un informe con cada respuesta completa para que una persona revise el resto.

Solo usa la biblioteca estándar. Cómo correrla (en el VPS):

    export AVIA_API_KEY=...        # la clave que nginx inyecta (está en supabase.env); vacío = sin auth
    export AVIA_TOKEN=...          # access_token de una sesión de la web (administrador o analista)
    python3 bateria.py --activas 8 --senal SEN-0418 --salida informe.md

  --url      dirección de avia-api (por defecto http://127.0.0.1:8099)
  --activas  las señales activas que muestra el panel ahora: comprueba que la pregunta 1 dice ese número
             y que la 7 no fuerza una cantidad
  --senal    una señal real (SEN-xxxx) para las preguntas 9 a 12; sin ella se saltan
  --solo     ids separados por comas (por ejemplo --solo 1,15,16)
  --doc      imprime la batería como tabla markdown (no llama a AVIA)

Resultado de cada pregunta: REVISAR (las reglas pasan; una persona juzga lo demás, como que el número
coincida con el panel), FALLA (incumple una regla) o SALTADA. Sale con código 1 si alguna FALLA. La
batería es la misma antes y después de una mejora: guarda el informe de cada ronda para compararlos.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

AQUI = os.path.dirname(os.path.abspath(__file__))
FLAGS = re.IGNORECASE | re.MULTILINE


def cargar(ruta):
    with open(ruta, encoding='utf-8') as f:
        return json.load(f)['preguntas']


def preguntar(url, clave, token, pregunta, rol='administrador', espera=90):
    cuerpo = json.dumps({'mensajes': [{'role': 'user', 'content': pregunta}], 'rol': rol}).encode()
    cab = {'Content-Type': 'application/json', 'X-Sb-Token': token}
    if clave:
        cab['Authorization'] = f'Bearer {clave}'
    req = urllib.request.Request(url.rstrip('/') + '/chat', data=cuerpo, headers=cab, method='POST')
    with urllib.request.urlopen(req, timeout=espera) as r:
        datos = json.loads(r.read().decode('utf-8'))
    return str(datos.get('texto', ''))


def evaluar(p, texto, activas=None):
    """Devuelve (estado, [motivos]). Estado: REVISAR (reglas ok) o FALLA."""
    fallos = []
    for rx in p.get('debe', []):
        if not re.search(rx, texto, FLAGS):
            fallos.append(f'falta algo que debía aparecer: /{rx}/')
    for rx in p.get('no_debe', []):
        m = re.search(rx, texto, FLAGS)
        if m:
            fallos.append(f'dice algo que no debía: «{m.group(0)}»')
    cond = p.get('debe_si_activas_menor_que')
    if cond and activas is not None and activas < cond['n'] and not re.search(cond['regex'], texto, FLAGS):
        fallos.append(f'hay {activas} señales activas (menos de {cond["n"]}) y no dice cuántas hay: parece que forzó la cantidad')
    if p.get('cuenta_activas') and activas is not None and not re.search(rf'\b{activas}\b', texto):
        fallos.append(f'el panel muestra {activas} señales activas y la respuesta no dice {activas}')
    if fallos:
        return 'FALLA', fallos
    return 'REVISAR', []


def tabla_doc(preguntas):
    f = ['| # | Paso | Pregunta | Qué se comprueba | Fallo del revisor que cubre |', '| --- | --- | --- | --- | --- |']
    for p in preguntas:
        f.append(f"| {p['id']} | {p['paso']} · {p['grupo']} | {p['pregunta'].replace('|', '/')} | {p['manual']} | {p.get('fallo_visto') or '—'} |")
    return '\n'.join(f)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url', default=os.environ.get('AVIA_URL', 'http://127.0.0.1:8099'))
    ap.add_argument('--bateria', default=os.path.join(AQUI, 'bateria.json'))
    ap.add_argument('--activas', type=int, help='señales activas que muestra el panel ahora')
    ap.add_argument('--senal', help='una señal real (SEN-xxxx) para las preguntas 9 a 12')
    ap.add_argument('--solo', help='ids separados por comas')
    ap.add_argument('--salida', default='informe-bateria.md')
    ap.add_argument('--doc', action='store_true')
    a = ap.parse_args()

    preguntas = cargar(a.bateria)
    if a.doc:
        print(tabla_doc(preguntas))
        return 0
    token = os.environ.get('AVIA_TOKEN', '').strip()
    if not token:
        print('Falta AVIA_TOKEN: el access_token de una sesión de la web (AVIA exige sesión iniciada).', file=sys.stderr)
        return 2
    clave = os.environ.get('AVIA_API_KEY', '')
    solo = {int(x) for x in a.solo.split(',')} if a.solo else None

    filas = []   # (pregunta, estado, motivos, texto de la pregunta, respuesta, segundos)
    for p in preguntas:
        if solo and p['id'] not in solo:
            continue
        if p.get('requiere_senal') and not a.senal:
            filas.append((p, 'SALTADA', ['falta --senal'], p['pregunta'], '', 0))
            print(f"{p['id']:>2}  SALTADA   {p['pregunta']}")
            continue
        q = p['pregunta'].replace('{senal}', a.senal or '')
        t0 = time.time()
        try:
            texto = preguntar(a.url, clave, token, q)
        except urllib.error.HTTPError as e:
            motivo = 'sesión o clave no válidas' if e.code == 401 else str(e.reason)
            filas.append((p, 'FALLA', [f'HTTP {e.code}: {motivo}'], q, '', 0))
            print(f"{p['id']:>2}  FALLA     {q}  (HTTP {e.code})")
            continue
        except Exception as e:   # red, tiempo de espera, JSON
            filas.append((p, 'FALLA', [f'no respondió: {e}'], q, '', 0))
            print(f"{p['id']:>2}  FALLA     {q}  ({e})")
            continue
        estado, motivos = evaluar(p, texto, a.activas)
        filas.append((p, estado, motivos, q, texto, round(time.time() - t0, 1)))
        print(f"{p['id']:>2}  {estado:<9} {q}")
        for m in motivos:
            print(f'      - {m}')

    n = lambda s: sum(1 for f in filas if f[1] == s)
    resumen = f"{n('REVISAR')} pasan las reglas (a revisar por una persona) · {n('FALLA')} fallan · {n('SALTADA')} saltadas"
    print('\n' + resumen)

    with open(a.salida, 'w', encoding='utf-8') as f:
        f.write(f"# Informe de la batería de AVIA\n\n{datetime.now().strftime('%Y-%m-%d %H:%M')} · {a.url} · "
                f"panel: {a.activas if a.activas is not None else 'sin dato'} señales activas · señal de prueba: {a.senal or 'ninguna'}\n\n{resumen}\n\n")
        f.write('| # | Resultado | Pregunta |\n| --- | --- | --- |\n')
        for fila in filas:
            f.write(f"| {fila[0]['id']} | {fila[1]} | {fila[3].replace('|', '/')} |\n")
        f.write('\n')
        for p, estado, motivos, q, texto, seg in filas:
            f.write(f"## {p['id']}. {p['grupo']} (paso {p['paso']}) — {estado}\n\n**Pregunta:** {q}\n\n")
            f.write(f"**Qué revisar a mano:** {p['manual']}\n\n")
            if p.get('fallo_visto'):
                f.write(f"**Fallo que vio el revisor:** {p['fallo_visto']}\n\n")
            for m in motivos:
                f.write(f'- ⚠ {m}\n')
            if texto:
                f.write(f"\n**Respuesta de AVIA** ({seg} s):\n\n" + '\n'.join('> ' + l for l in texto.splitlines()) + '\n')
            f.write('\n')
    print(f'Informe: {a.salida}')
    return 1 if n('FALLA') else 0


if __name__ == '__main__':
    sys.exit(main())
