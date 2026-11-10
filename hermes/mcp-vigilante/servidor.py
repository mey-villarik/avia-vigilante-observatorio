#!/usr/bin/env python3
"""MCP propio del Vigilante: las herramientas con las que AVIA (motor Hermes) trabaja sobre nuestra Supabase.

Desde la versión 2.0 (migración 15) Hermes es el AGENTE INVESTIGADOR, no el clasificador:
  - el recolector (sin IA) lee las fuentes del catálogo y detecta cambios;
  - el analizador (modelo breve, sin Hermes) clasifica las noticias nuevas y crea las señales;
  - Hermes solo atiende las TAREAS que necesitan investigar: corroborar, resolver una contradicción,
    relacionar señales u oportunidades inferidas, y escribe el radar diario.
Hermes no puede crear fuentes (solo proponer candidatas con evidencia) ni señales sin noticias recogidas.

Servidor MCP por stdio (JSON-RPC 2.0, un mensaje por línea). Solo biblioteca estándar de Python 3.9+.
Variables: las mismas que el recolector (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE),
en /etc/avia/supabase.env o en el archivo que diga AVIA_SUPABASE_ENV.

Probar a mano:
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 servidor.py
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

VERSION = '2.0.0'

INSTRUCCIONES = (
    'Herramientas del Vigilante AVIA sobre la base de datos del observatorio. Eres el agente investigador: '
    'tomar_tareas → investiga cada una (buscar_senales, pedir_busqueda, el MCP de AVIA) → guardar_senal (solo para '
    'ACTUALIZAR con codigo, o nueva con noticias que existen), guardar_oportunidad (con evidencias) → terminar_tarea. '
    'La procedencia (fuente, enlace) la pone la base desde las noticias: no la escribas. Si ves una fuente que convendría '
    'vigilar, proponer_fuente (queda como candidata). Nunca inventes datos. Una persona decide qué se publica.'
)


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


def rpc(fn: str, args: dict) -> object:
    url = os.environ['SUPABASE_URL'].rstrip('/')
    key = os.environ['SUPABASE_SERVICE_ROLE_KEY']
    cab = {'apikey': key, 'Content-Type': 'application/json', 'Content-Profile': 'vigilante', 'Accept-Profile': 'vigilante'}
    if not key.startswith('sb_'):
        cab['Authorization'] = f'Bearer {key}'
    args = {'p_cliente': os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia'), **args}
    req = urllib.request.Request(f'{url}/rest/v1/rpc/{fn}', data=json.dumps(args).encode(), headers=cab, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            cuerpo = r.read()
    except urllib.error.HTTPError as e:
        detalle = e.read()[:400].decode(errors='replace')
        try:
            detalle = json.loads(detalle).get('message', detalle)
        except (ValueError, AttributeError):
            pass
        raise RuntimeError(detalle) from None
    return json.loads(cuerpo) if cuerpo else None


METODOS = ['rss', 'google_news_rss', 'gdelt', 'http_html', 'apify', 'tavily', 'api', 'mcp_vigilante', 'manual']

SENAL = {
    'type': 'object',
    'description': 'Señal para el sector turismo. Copia tal cual cifras, fechas, plazos y nombres; si un dato falta, no lo pongas.',
    'properties': {
        'codigo': {'type': 'string', 'description': 'Solo para ACTUALIZAR una señal existente (SEN-xxxx). Para una nueva, no lo mandes.'},
        'titulo': {'type': 'string', 'description': 'Máx. 100 caracteres, con lugar y fecha'},
        'resumen': {'type': 'string', 'description': '1 o 2 frases, solo hechos de la fuente'},
        'recomendacion': {'type': 'string', 'description': 'Qué hace el sector turismo'},
        'naturaleza': {'type': 'string', 'enum': ['riesgo', 'oportunidad', 'mixta']},
        'categoria': {'type': 'string', 'description': 'clima, salud, vial, seguridad, conectividad, eventos, financiamiento, mercados, normativa'},
        'prioridad': {'type': 'string', 'enum': ['alta', 'media', 'baja']},
        'motivos_prioridad': {'type': 'array', 'items': {'type': 'string'}},
        'departamentos': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Nombres de departamentos'},
        'destinos': {'type': 'array', 'items': {'type': 'string'}},
        'alcance_nacional': {'type': 'boolean'},
        'fecha_evento_inicio': {'type': 'string', 'description': 'AAAA-MM-DD o ISO 8601 con -04:00'},
        'fecha_evento_fin': {'type': 'string'},
        'plazo_hasta': {'type': 'string', 'description': 'AAAA-MM-DD: cierre de una convocatoria o plazo'},
        'enlace_oficial': {'type': 'string', 'description': 'Solo una dirección que aparece en las noticias de la señal. '
                                                            'Si no hay enlace oficial comprobado, NO lo mandes: la base pide verificación.'},
        'requiere_revision': {'type': 'boolean'},
        'es_escenario': {'type': 'boolean', 'description': 'Proyección o predicción: true y la palabra «escenario» en el título'},
        'confianza': {'type': 'number', 'minimum': 0, 'maximum': 1},
        'relevancia': {'type': 'number', 'minimum': 0, 'maximum': 10},
        'novedad': {'type': 'number', 'minimum': 0, 'maximum': 10},
        'tipo_oportunidad': {'type': 'string', 'description': 'Evento, Financiación, Inversión, Conectividad, Normativa, Demanda…'},
        'actores': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Quién puede aprovecharla'},
        'importancia': {'type': 'string', 'description': 'Por qué importa al turismo, 2 frases'},
        'soluciones': {'type': 'array', 'items': {'type': 'object', 'properties': {'t': {'type': 'string'}, 'd': {'type': 'string'}}},
                       'description': 'Acciones concretas: t = acción, d = detalle'},
        'noticias': {'type': 'array', 'items': {'type': 'integer'},
                     'description': 'ids de noticias recogidas que sostienen la señal (obligatorio para una nueva)'},
        'contexto_vigilante': {'type': 'object', 'description': 'Lo que devolvió el MCP de AVIA (antecedentes), si lo consultaste'},
    },
    'required': ['titulo', 'resumen'],
}

HERRAMIENTAS = [
    {'name': 'tomar_tareas',
     'description': 'Tareas que el clasificador o una regla dejaron para ti: corroborar, contradiccion, relacionar, '
                    'oportunidad_inferida o radar. Cada una trae su señal y sus noticias. Quedan reservadas 2 horas: '
                    'ciérralas con terminar_tarea.',
     'inputSchema': {'type': 'object', 'properties': {'limite': {'type': 'integer', 'minimum': 1, 'maximum': 20, 'default': 5}}},
     'fn': 'tomar_tareas', 'args': lambda a: {'p_limite': a.get('limite', 5)}},
    {'name': 'terminar_tarea',
     'description': 'Cierra una tarea: «hecha» con lo que encontraste (resultado) o «descartada» con el motivo.',
     'inputSchema': {'type': 'object', 'properties': {
         'id': {'type': 'integer'}, 'estado': {'type': 'string', 'enum': ['hecha', 'descartada']},
         'resultado': {'type': 'object', 'description': 'p. ej. {"corroborada": true, "noticias": [ids], "nota": "..."}'}},
         'required': ['id', 'estado']},
     'fn': 'terminar_tarea', 'args': lambda a: {'p_id': a['id'], 'p_estado': a['estado'], 'p_resultado': a.get('resultado') or {}}},
    {'name': 'guardar_oportunidad',
     'description': 'Guarda una oportunidad apoyada en noticias de la base. Separa HECHO (lo que dice la fuente) de '
                    'INTERPRETACIÓN (qué podría aprovechar el sector). Inferida = necesita interpretación y la palabra '
                    '«podría»; no afirmes efectos sin datos. Queda como «propuesta» hasta que una persona la valide.',
     'inputSchema': {'type': 'object', 'properties': {'oportunidad': {'type': 'object', 'properties': {
         'senal': {'type': 'string', 'description': 'Código SEN-xxxx si sale de una señal'},
         'nivel': {'type': 'string', 'enum': ['explicita', 'inferida'], 'default': 'inferida'},
         'tipo': {'type': 'string', 'description': 'convocatoria, licitacion, evento, conectividad, financiamiento, formacion, normativa, demanda'},
         'hecho': {'type': 'string'}, 'interpretacion': {'type': 'string'},
         'beneficiarios': {'type': 'array', 'items': {'type': 'string'}}, 'accion': {'type': 'string'},
         'plazo_hasta': {'type': 'string', 'description': 'AAAA-MM-DD si la fuente lo da'},
         'importancia': {'type': 'integer', 'minimum': 1, 'maximum': 5},
         'evidencias': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'ids de noticias de la base (obligatorio)'}},
         'required': ['tipo', 'hecho', 'evidencias']}}, 'required': ['oportunidad']},
     'fn': 'guardar_oportunidad', 'args': lambda a: {'p_op': a['oportunidad']}},
    {'name': 'proponer_fuente',
     'description': 'Propone vigilar una fuente que NO está en el catálogo. No la crea: queda como candidata y un '
                    'administrador decide. Necesita una dirección real vista en noticias de la base (evidencia = sus ids).',
     'inputSchema': {'type': 'object', 'properties': {
         'nombre': {'type': 'string'}, 'url': {'type': 'string'}, 'motivo': {'type': 'string'},
         'tipo': {'type': 'string', 'enum': ['oficial', 'organismo_internacional', 'medio', 'no_oficial']},
         'evidencia': {'type': 'array', 'items': {'type': 'integer'}}}, 'required': ['nombre', 'url', 'motivo', 'evidencia']},
     'fn': 'proponer_fuente', 'args': lambda a: {'p_nombre': a['nombre'], 'p_url': a['url'], 'p_motivo': a['motivo'],
                                                  'p_evidencia': a.get('evidencia') or [], 'p_tipo': a.get('tipo')}},
    {'name': 'guardar_senal',
     'description': 'Actualiza una señal existente (con codigo) tras investigar, o guarda una nueva si hay noticias '
                    'recogidas que la sostienen (noticias = sus ids; sin ellas la base la rechaza). La fuente, si es '
                    'oficial y el enlace los pone la base. Queda en «Detectada» hasta que una persona la revise.',
     'inputSchema': {'type': 'object', 'properties': {'senal': SENAL}, 'required': ['senal']},
     'fn': 'guardar_senal', 'args': lambda a: {'p_senal': a['senal']}},
    {'name': 'buscar_senales',
     'description': 'Busca señales ya guardadas (por texto, días y naturaleza) para no repetirlas y para dar contexto.',
     'inputSchema': {'type': 'object', 'properties': {
         'texto': {'type': 'string'}, 'dias': {'type': 'integer', 'default': 30},
         'naturaleza': {'type': 'string', 'enum': ['riesgo', 'oportunidad', 'mixta']},
         'limite': {'type': 'integer', 'default': 10, 'maximum': 50}}},
     'fn': 'buscar_senales', 'args': lambda a: {'p_texto': a.get('texto'), 'p_dias': a.get('dias', 30),
                                                 'p_naturaleza': a.get('naturaleza'), 'p_limite': a.get('limite', 10)}},
    {'name': 'estado_fuentes',
     'description': 'Estado de cada fuente: cómo se lee, último resultado, fallos seguidos, noticias y noticias útiles en 24 h, '
                    'y si ya hay una propuesta pendiente.',
     'inputSchema': {'type': 'object', 'properties': {}}, 'fn': 'estado_fuentes', 'args': lambda a: {}},
    {'name': 'proponer_metodo',
     'description': 'Propone cambiar cómo se lee una fuente (por ejemplo, a Apify si el script no puede leerla, o a RSS si '
                    'tiene uno). NO la cambia: un administrador la aprueba en la web. Úsala solo con un motivo claro '
                    '(fallos seguidos, cero noticias útiles, sitio que bloquea lectores). Apify cuesta dinero.',
     'inputSchema': {'type': 'object', 'properties': {
         'codigo': {'type': 'string'}, 'metodo': {'type': 'string', 'enum': METODOS},
         'motivo': {'type': 'string'},
         'config': {'type': 'object', 'description': 'Opcional: {"apify_actor": "...", "apify_input": {...}} o {"query": "..."}'}},
         'required': ['codigo', 'metodo', 'motivo']},
     'fn': 'proponer_metodo', 'args': lambda a: {'p_codigo': a['codigo'], 'p_metodo': a['metodo'], 'p_motivo': a['motivo'],
                                                  'p_config': a.get('config') or {}}},
    {'name': 'pedir_busqueda',
     'description': 'Deja una búsqueda extra en la cola (por ejemplo, un tema que crece o algo que corroborar). La hace el '
                    'recolector en los próximos minutos: via «script» = Google News + GDELT (gratis); via «apify» = '
                    'solo para redes o webs que el script no puede leer, con tope de gasto. Hay un máximo diario.',
     'inputSchema': {'type': 'object', 'properties': {
         'consulta': {'type': 'string'}, 'via': {'type': 'string', 'enum': ['script', 'apify'], 'default': 'script'},
         'motivo': {'type': 'string'}, 'dias': {'type': 'integer', 'default': 7, 'minimum': 1, 'maximum': 30},
         'apify_actor': {'type': 'string'}, 'apify_input': {'type': 'object'}}, 'required': ['consulta', 'motivo']},
     'fn': 'pedir_busqueda', 'args': lambda a: {
         'p_consulta': a['consulta'], 'p_via': a.get('via', 'script'), 'p_motivo': a.get('motivo'),
         'p_parametros': {k: v for k, v in {'dias': a.get('dias', 7), 'apify_actor': a.get('apify_actor'),
                                             'apify_input': a.get('apify_input')}.items() if v is not None}}},
    {'name': 'metricas_oportunidades',
     'description': 'Métricas calculadas en SQL (sin IA): oportunidades vigentes con días hasta el plazo o el evento, '
                    'eventos de los próximos 60 días, impulso por territorio (menciones de 7 días frente a la media semanal '
                    'anterior) y temas que aparecen en varias fuentes. Úsalas para el radar diario de oportunidades.',
     'inputSchema': {'type': 'object', 'properties': {}}, 'fn': 'metricas_oportunidades', 'args': lambda a: {}},
    {'name': 'alertas_tempranas',
     'description': 'Lo que una regla marca para mirar ya: aviso oficial con palabra de alerta, mismo hecho en 3 o más '
                    'fuentes en 6 horas, plazo que cierra en 5 días, territorio con el doble de menciones de lo normal.',
     'inputSchema': {'type': 'object', 'properties': {}}, 'fn': 'alertas_tempranas', 'args': lambda a: {}},
]
POR_NOMBRE = {h['name']: h for h in HERRAMIENTAS}


def responder(id_, resultado=None, error=None) -> None:
    msg = {'jsonrpc': '2.0', 'id': id_}
    if error is not None:
        msg['error'] = error
    else:
        msg['result'] = resultado
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + '\n')
    sys.stdout.flush()


def manejar(m: dict) -> None:
    metodo, id_ = m.get('method'), m.get('id')
    if id_ is None:  # notificación (p. ej. notifications/initialized): no se responde
        return
    if metodo == 'initialize':
        version = (m.get('params') or {}).get('protocolVersion') or '2025-06-18'
        responder(id_, {'protocolVersion': version, 'capabilities': {'tools': {'listChanged': False}},
                        'serverInfo': {'name': 'avia-vigilante', 'version': VERSION}, 'instructions': INSTRUCCIONES})
    elif metodo == 'ping':
        responder(id_, {})
    elif metodo == 'tools/list':
        responder(id_, {'tools': [{k: h[k] for k in ('name', 'description', 'inputSchema')} for h in HERRAMIENTAS]})
    elif metodo == 'tools/call':
        p = m.get('params') or {}
        h = POR_NOMBRE.get(p.get('name'))
        if not h:
            responder(id_, error={'code': -32602, 'message': f'Herramienta desconocida: {p.get("name")}'})
            return
        try:
            datos = rpc(h['fn'], h['args'](p.get('arguments') or {}))
            # JSON compacto: menos tokens para el modelo
            texto = json.dumps(datos, ensure_ascii=False, separators=(',', ':'), default=str)
            responder(id_, {'content': [{'type': 'text', 'text': texto}], 'isError': False})
        except (KeyError, TypeError) as e:
            responder(id_, {'content': [{'type': 'text', 'text': f'Falta un dato obligatorio: {e}'}], 'isError': True})
        except Exception as e:  # noqa: BLE001 — el error vuelve al modelo como texto
            responder(id_, {'content': [{'type': 'text', 'text': f'Error: {e}'}], 'isError': True})
    else:
        responder(id_, error={'code': -32601, 'message': f'Método no soportado: {metodo}'})


def main() -> None:
    cargar_env()
    for linea in sys.stdin:
        linea = linea.strip()
        if not linea:
            continue
        try:
            m = json.loads(linea)
        except json.JSONDecodeError:
            responder(None, error={'code': -32700, 'message': 'JSON no válido'})
            continue
        for x in (m if isinstance(m, list) else [m]):
            manejar(x)


if __name__ == '__main__':
    main()
