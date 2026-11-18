#!/usr/bin/env python3
"""Batería de pruebas de AVIA (mejora 10 de la PoC, documento del revisor).

Hace las 20 preguntas de bateria.json al chat de avia-api, comprueba lo que se puede comprobar con
reglas (que aparezcan los bloques, que no afirme una ruta como operativa, que cite la hora de los datos...)
y escribe un informe con cada respuesta completa para que una persona revise el resto.

Solo usa la biblioteca estándar. En el VPS basta con:

    cd /root/avia-repo/hermes/avia-api
    python3 bateria.py --etiqueta antes

Todo lo demás lo saca solo de /root/avia/supabase.env (o /etc/avia/supabase.env):
  - AVIA_API_KEY: la clave que nginx inyecta (vacía = sin auth).
  - La sesión: inicia sesión como el primer administrador activo de vigilante.users (o AVIA_BATERIA_EMAIL)
    con SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY. Si prefieres otra sesión, exporta AVIA_TOKEN.
  - Las señales activas (para las preguntas 1 y 7) y una señal real para las preguntas 9 a 12, leídas de
    vigilante_bd() igual que el panel. Se pueden forzar con --activas y --senal.

  --url       dirección de avia-api (por defecto http://127.0.0.1:8099)
  --activas   las señales activas que muestra el panel (si no, las cuenta de la base)
  --senal     una señal real (SEN-xxxx) para las preguntas 9 a 12 (si no, elige una activa)
  --solo      ids separados por comas (por ejemplo --solo 1,15,16)
  --etiqueta  nombre corto de la ronda (antes, despues, paso3...) que va en el nombre del informe
  --salida    ruta del informe (por defecto informes/AAAA-MM-DD_HHMM_<etiqueta>.md)
  --comparar  A B: compara dos rondas ya guardadas (.md o .json) sin llamar a AVIA
  --doc       imprime la batería como tabla markdown (no llama a AVIA)

Resultado de cada pregunta: REVISAR (las reglas pasan; una persona juzga lo demás, como que el número
coincida con el panel), FALLA (incumple una regla) o SALTADA. Sale con código 1 si alguna FALLA. Cada ronda
deja un .md para leer y un .json con los mismos datos para comparar.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

AQUI = os.path.dirname(os.path.abspath(__file__))
FLAGS = re.IGNORECASE | re.MULTILINE

ENV_FILES = [os.environ.get('AVIA_SUPABASE_ENV', ''), '/etc/avia/supabase.env',
             os.path.expanduser('~/avia/supabase.env'), '/root/avia/supabase.env']


def cargar_env():
    """Lee los archivos de claves del VPS (sin pisar lo que ya esté exportado). Devuelve los que encontró."""
    leidos = []
    for ruta in ENV_FILES:
        if not ruta or not os.path.isfile(ruta) or ruta in leidos:
            continue
        try:
            with open(ruta, encoding='utf-8') as f:
                for linea in f:
                    linea = linea.strip()
                    if linea.startswith('export '):
                        linea = linea[7:]
                    if linea and not linea.startswith('#') and '=' in linea:
                        k, _, v = linea.partition('=')
                        k, v = k.strip(), v.strip().strip('"').strip("'")
                        if k and k not in os.environ:
                            os.environ[k] = v
            leidos.append(ruta)
        except OSError:
            pass
    return leidos


def _http(metodo, url, cuerpo=None, cab=None, espera=20):
    datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(url, data=datos, method=metodo, headers={'Content-Type': 'application/json', **(cab or {})})
    with urllib.request.urlopen(req, timeout=espera) as r:
        txt = r.read().decode('utf-8')
    return json.loads(txt) if txt else None


def _cab_servicio(clave):
    cab = {'apikey': clave}
    if clave.startswith('eyJ'):          # clave service_role antigua (JWT); las nuevas sb_secret_ van solo en apikey
        cab['Authorization'] = f'Bearer {clave}'
    return cab


class _SinRedireccion(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def iniciar_sesion(sb_url, sb_key, email=None):
    """Consigue un access_token sin pasar por el navegador: enlace mágico generado con la clave de servicio
    (no envía ningún correo). Devuelve (token, email)."""
    cab = _cab_servicio(sb_key)
    if not email:
        perfil = {**cab, 'Accept-Profile': 'vigilante'}
        filas = _http('GET', f'{sb_url}/rest/v1/users?select=email,auth_user_id&rol=eq.administrador'
                             '&activo=is.true&auth_user_id=not.is.null&order=created_at&limit=1', cab=perfil) or []
        if not filas:
            raise RuntimeError('no hay ningún administrador activo con cuenta en vigilante.users')
        email = filas[0].get('email')
        if not email:
            email = (_http('GET', f"{sb_url}/auth/v1/admin/users/{filas[0]['auth_user_id']}", cab=cab) or {}).get('email')
    if not email:
        raise RuntimeError('el administrador no tiene correo; exporta AVIA_BATERIA_EMAIL')
    enlace = _http('POST', f'{sb_url}/auth/v1/admin/generate_link', {'type': 'magiclink', 'email': email}, cab) or {}
    props = enlace.get('properties') or {}
    hashed = enlace.get('hashed_token') or props.get('hashed_token')
    if hashed:
        try:
            ses = _http('POST', f'{sb_url}/auth/v1/verify', {'type': 'magiclink', 'token_hash': hashed}, {'apikey': sb_key})
            if ses and ses.get('access_token'):
                return ses['access_token'], email
        except urllib.error.HTTPError:
            pass
    accion = enlace.get('action_link') or props.get('action_link')
    if accion:   # plan B: seguir el enlace y leer el token de la redirección
        try:
            urllib.request.build_opener(_SinRedireccion).open(accion, timeout=20)
        except urllib.error.HTTPError as e:
            m = re.search(r'access_token=([^&]+)', e.headers.get('Location', ''))
            if m:
                return urllib.parse.unquote(m.group(1)), email
    raise RuntimeError('Supabase no devolvió una sesión para ' + email)


def datos_panel(sb_url, sb_key, token):
    """Las señales activas y una señal de prueba, de vigilante_bd() (la misma lista que ven el panel y AVIA)."""
    cab = {'apikey': sb_key, 'Authorization': f'Bearer {token}',
           'Content-Profile': 'vigilante', 'Accept-Profile': 'vigilante'}
    ctx = _http('POST', f'{sb_url}/rest/v1/rpc/vigilante_bd', {}, cab, espera=30)
    if not isinstance(ctx, dict) or 'senales' not in ctx:
        raise RuntimeError(f'vigilante_bd respondió algo inesperado: {str(ctx)[:200]}')
    activas = [x for x in ctx.get('senales') or [] if isinstance(x, dict) and x.get('estado') != 'descartada']
    k = ctx.get('contadores') or {}
    n = k.get('senales_activas', len(activas))
    orden = {'alta': 0, 'media': 1, 'baja': 2}
    con_id = [x for x in activas if re.fullmatch(r'SEN-\d+', str(x.get('id', '')))]
    con_id.sort(key=lambda x: (orden.get(x.get('prioridad'), 3), -len(x.get('enlaces') or [])))
    return int(n), (con_id[0]['id'] if con_id else None)



def cargar(ruta):
    with open(ruta, encoding='utf-8') as f:
        return json.load(f)['preguntas']


def preguntar(url, clave, token, pregunta, rol='administrador', espera=90):
    cuerpo = json.dumps({'mensajes': [{'role': 'user', 'content': pregunta}], 'rol': rol}).encode()
    # X-Sb-Token para el avia_api.py actual y la cookie para versiones anteriores que solo leen la cookie
    ck = 'sb-bateria-auth-token=' + urllib.parse.quote(json.dumps({'access_token': token}))
    cab = {'Content-Type': 'application/json', 'X-Sb-Token': token, 'Cookie': ck}
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


def _ruta_json(ruta):
    return ruta[:-3] + '.json' if ruta.endswith('.md') else ruta


def comparar(ruta_a, ruta_b, salida=None):
    """Compara dos rondas pregunta a pregunta: qué pasó a pasar las reglas, qué empeoró y qué sigue igual."""
    a, b = (json.load(open(_ruta_json(r), encoding='utf-8')) for r in (ruta_a, ruta_b))
    ra = {r['id']: r for r in a['resultados']}
    rb = {r['id']: r for r in b['resultados']}
    ok = lambda r: r is not None and r['estado'] == 'REVISAR'
    lineas = [f"# Comparación de la batería de AVIA\n",
              f"- **A:** {a['fecha']} · {a.get('etiqueta') or '—'} · {a['resumen']}",
              f"- **B:** {b['fecha']} · {b.get('etiqueta') or '—'} · {b['resumen']}\n",
              '| # | Grupo | A | B | Cambio |', '| --- | --- | --- | --- | --- |']
    cuenta = {'mejora': 0, 'empeora': 0, 'igual': 0}
    for i in sorted(set(ra) | set(rb)):
        x, y = ra.get(i), rb.get(i)
        if ok(y) and x is not None and x['estado'] == 'FALLA':
            cambio = 'mejora'
        elif y is not None and y['estado'] == 'FALLA' and ok(x):
            cambio = 'empeora'
        else:
            cambio = 'igual'
        cuenta[cambio] += 1
        grupo = (y or x)['grupo']
        marca = {'mejora': '✅ mejora', 'empeora': '❌ empeora', 'igual': '='}[cambio]
        lineas.append(f"| {i} | {grupo} | {x['estado'] if x else '—'} | {y['estado'] if y else '—'} | {marca} |")
    lineas.append(f"\n{cuenta['mejora']} mejoran · {cuenta['empeora']} empeoran · {cuenta['igual']} igual\n")
    lineas.append('Las que siguen en REVISAR en ambas rondas hay que leerlas a mano en los dos informes '
                  '(sección de cada pregunta) con el criterio «Qué revisar a mano».')
    detalle = []
    for i in sorted(set(ra) | set(rb)):
        x, y = ra.get(i), rb.get(i)
        if (x and x['motivos']) or (y and y['motivos']):
            detalle.append(f"\n### {i}. {(y or x)['pregunta']}\n")
            for nombre, r in (('A', x), ('B', y)):
                if r and r['motivos']:
                    detalle += [f'- {nombre}: {m}' for m in r['motivos']]
    if detalle:
        lineas.append('\n## Motivos de los fallos\n' + '\n'.join(detalle))
    texto = '\n'.join(lineas) + '\n'
    print(texto)
    if salida:
        with open(salida, 'w', encoding='utf-8') as f:
            f.write(texto)
        print(f'Comparación: {salida}')
    return 1 if cuenta['empeora'] else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url', default=os.environ.get('AVIA_URL', 'http://127.0.0.1:8099'))
    ap.add_argument('--bateria', default=os.path.join(AQUI, 'bateria.json'))
    ap.add_argument('--activas', type=int, help='señales activas que muestra el panel ahora')
    ap.add_argument('--senal', help='una señal real (SEN-xxxx) para las preguntas 9 a 12')
    ap.add_argument('--solo', help='ids separados por comas')
    ap.add_argument('--etiqueta', default='', help='nombre corto de la ronda: antes, despues, paso3...')
    ap.add_argument('--salida', help='ruta del informe .md (por defecto informes/AAAA-MM-DD_HHMM_<etiqueta>.md)')
    ap.add_argument('--comparar', nargs=2, metavar=('A', 'B'), help='compara dos informes ya guardados')
    ap.add_argument('--doc', action='store_true')
    a = ap.parse_args()

    if a.comparar:
        return comparar(*a.comparar, salida=a.salida)
    preguntas = cargar(a.bateria)
    if a.doc:
        print(tabla_doc(preguntas))
        return 0

    leidos = cargar_env()
    print('Claves leídas de: ' + (', '.join(leidos) if leidos else 'ninguna (solo variables exportadas)'))
    sb_url = os.environ.get('SUPABASE_URL', '').rstrip('/')
    sb_key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
    clave = os.environ.get('AVIA_API_KEY', '')

    # ¿Está avia-api arriba?
    try:
        _http('GET', a.url.rstrip('/') + '/health', espera=5)
    except Exception as e:
        print(f'avia-api no responde en {a.url} ({e}). Mira: systemctl status avia-api', file=sys.stderr)
        return 2

    token = os.environ.get('AVIA_TOKEN', '').strip()
    quien = 'AVIA_TOKEN'
    if not token:
        if not (sb_url and sb_key):
            print('Falta la sesión: no hay AVIA_TOKEN ni SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY en supabase.env.',
                  file=sys.stderr)
            return 2
        try:
            token, quien = iniciar_sesion(sb_url, sb_key, os.environ.get('AVIA_BATERIA_EMAIL', '').strip() or None)
        except Exception as e:
            print(f'No pude iniciar sesión en Supabase: {e}. Alternativa: export AVIA_TOKEN=<access_token de la web>',
                  file=sys.stderr)
            return 2
    print(f'Sesión: {quien}')

    if (a.activas is None or not a.senal) and sb_url and sb_key:
        try:
            n, senal = datos_panel(sb_url, sb_key, token)
            if a.activas is None:
                a.activas = n
                print(f'Señales activas según la base: {n} (si el panel muestra otro número, usa --activas)')
            if not a.senal and senal:
                a.senal = senal
                print(f'Señal de prueba para las preguntas 9 a 12: {senal}')
        except Exception as e:
            print(f'No pude leer vigilante_bd ({e}): sigo sin --activas ni --senal automáticos')

    solo = {int(x) for x in a.solo.split(',')} if a.solo else None
    if not a.salida:
        os.makedirs(os.path.join(AQUI, 'informes'), exist_ok=True)
        nombre = datetime.now().strftime('%Y-%m-%d_%H%M') + (f'_{a.etiqueta}' if a.etiqueta else '') + '.md'
        a.salida = os.path.join(AQUI, 'informes', nombre)
    print()

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
    fecha = datetime.now().strftime('%Y-%m-%d %H:%M')

    with open(a.salida, 'w', encoding='utf-8') as f:
        f.write(f"# Informe de la batería de AVIA{' — ' + a.etiqueta if a.etiqueta else ''}\n\n{fecha} · {a.url} · "
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
    with open(_ruta_json(a.salida), 'w', encoding='utf-8') as f:
        json.dump({'fecha': fecha, 'etiqueta': a.etiqueta, 'url': a.url, 'activas': a.activas, 'senal': a.senal,
                   'resumen': resumen,
                   'resultados': [{'id': p['id'], 'grupo': p['grupo'], 'paso': p['paso'], 'pregunta': q,
                                   'estado': estado, 'motivos': motivos, 'respuesta': texto, 'segundos': seg}
                                  for p, estado, motivos, q, texto, seg in filas]},
                  f, ensure_ascii=False, indent=1)
    print(f'Informe: {a.salida}\nDatos para comparar: {_ruta_json(a.salida)}')
    return 1 if n('FALLA') else 0


if __name__ == '__main__':
    sys.exit(main())
