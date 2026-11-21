#!/usr/bin/env python3
"""AVIA Chat API – adaptador entre la web y DeepSeek con contexto de Supabase.

Protocolo (igual que el contrato en web/src/services/avia.ts):
  POST /chat     { mensajes, rol }                           -> { texto, comandos? }
  POST /analisis { tipo, territorio, pregunta?, senales }    -> { texto }
  POST /evaluar  { texto }                                   -> Evaluacion
  GET  /health                                               -> { ok: true }

Secretos (de ~/avia/supabase.env):
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, LLM_API_KEY
  VIGILANTE_CLIENTE   (opcional; por defecto orbita-bolivia)
  AVIA_API_KEY        (clave que nginx inyecta en Authorization; vacío = sin auth)
  AVIA_PORT           (opcional; por defecto 8099)

Instalación (VPS):
  pip3 install aiohttp
  cp avia_api.py /root/avia/avia_api.py
  systemctl enable --now avia-api   # ver avia-api.service

Nunca pongas LLM_API_KEY ni SUPABASE_SERVICE_ROLE_KEY en Git ni en variables VITE_.
"""

import json, os, re, sys, time, urllib.parse
from pathlib import Path

# ── aiohttp es la única dependencia externa ───────────────────────────────────
try:
    import aiohttp
    from aiohttp import web
except ImportError:
    sys.exit("Falta aiohttp. Instala con:  pip3 install aiohttp")


# ── Cargar secretos desde el archivo de entorno ───────────────────────────────
def _load_env_file(path: str) -> None:
    if not path:
        return
    try:
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, _, v = line.partition('=')
                k = k.strip()
                if k and k not in os.environ:   # no sobreescribir variables del sistema
                    os.environ[k] = v.strip()
    except FileNotFoundError:
        pass


_load_env_file(os.environ.get('AVIA_SUPABASE_ENV', ''))
_load_env_file('/etc/avia/supabase.env')
_load_env_file(os.path.expanduser('~/avia/supabase.env'))

SB_URL    = os.environ.get('SUPABASE_URL', '').rstrip('/')
SB_KEY    = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
LLM_KEY   = os.environ.get('LLM_API_KEY') or os.environ.get('DEEPSEEK_API_KEY', '')
LLM_BASE  = os.environ.get('LLM_BASE_URL', 'https://api.deepseek.com').rstrip('/')
LLM_MODEL = os.environ.get('LLM_MODEL', 'deepseek-chat')
CLIENTE   = os.environ.get('VIGILANTE_CLIENTE', 'orbita-bolivia')
API_KEY   = os.environ.get('AVIA_API_KEY', '')   # nginx inyecta este valor en el header
PORT      = int(os.environ.get('AVIA_PORT', '8099'))

_CTX_TTL  = 60    # segundos que se cachea el contexto de Supabase (la web recarga antes de preguntar)
_ctx_cache: dict = {}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _check_auth(request: web.Request) -> bool:
    """Valida que la petición venga de nginx (que inyecta AVIA_API_KEY)."""
    if not API_KEY:
        return True   # sin clave: modo desarrollo
    return request.headers.get('Authorization', '') == f'Bearer {API_KEY}'


def _extract_jwt(cookie_header: str) -> str | None:
    """Extrae el access_token de las cookies de sesión de Supabase, si existe."""
    for part in cookie_header.split(';'):
        m = re.match(r'\s*sb-.+-auth-token=(.+)', part.strip())
        if m:
            try:
                data = json.loads(urllib.parse.unquote(m.group(1)))
                return data.get('access_token')
            except Exception:
                pass
    return None


async def _supabase_post(session: aiohttp.ClientSession, path: str,
                         body: dict, jwt: str | None = None) -> dict | list:
    headers = {
        'apikey': SB_KEY,
        'Authorization': f'Bearer {jwt or SB_KEY}',
        'Content-Type': 'application/json',
        # vigilante_bd() vive en el esquema «vigilante», no en «public» (sin esto Supabase responde 404 y el chat veía 0 señales)
        'Content-Profile': 'vigilante',
        'Accept-Profile': 'vigilante',
    }
    async with session.post(f'{SB_URL}{path}', json=body, headers=headers) as r:
        return await r.json()


async def _deepseek(session: aiohttp.ClientSession,
                    messages: list, max_tokens: int = 600) -> str:
    async with session.post(
        f'{LLM_BASE}/v1/chat/completions',
        headers={'Authorization': f'Bearer {LLM_KEY}',
                 'Content-Type': 'application/json'},
        json={'model': LLM_MODEL, 'messages': messages, 'max_tokens': max_tokens},
        timeout=aiohttp.ClientTimeout(total=60),
    ) as r:
        data = await r.json(content_type=None)
    if not isinstance(data, dict) or not data.get('choices'):
        # el proveedor del modelo devolvió un error (sin saldo, clave mala, modelo inexistente…): que se vea en el log
        err = data.get('error') if isinstance(data, dict) else data
        raise RuntimeError(f'LLM {LLM_BASE} modelo {LLM_MODEL} HTTP {r.status}: {str(err)[:300]}')
    return data['choices'][0]['message']['content']


async def _get_context(session: aiohttp.ClientSession, jwt: str | None) -> dict:
    """Llama a vigilante_bd() en Supabase y devuelve el contexto actual (cacheado 2 min)."""
    key = jwt or '__anon__'
    cached = _ctx_cache.get(key)
    if cached and time.time() - cached[0] < _CTX_TTL:
        return cached[1]
    try:
        ctx = await _supabase_post(session, '/rest/v1/rpc/vigilante_bd', {}, jwt)
        if isinstance(ctx, dict) and 'senales' in ctx:
            _ctx_cache[key] = (time.time(), ctx)
            if not ctx.get('senales'):
                print('vigilante_bd: respondió sin señales', flush=True)
            return ctx
        # Antes esto se callaba y el chat decía «no tengo señales»: ahora queda en journalctl -u avia-api
        print(f'vigilante_bd: respuesta inesperada: {json.dumps(ctx, ensure_ascii=False)[:300]}', flush=True)
    except Exception as e:
        print(f'vigilante_bd: error al consultar Supabase: {e!r}', flush=True)
    return {}


# ── Glosario único (igual que web/src/lib/glosario.ts y docs/glosario.md) ─────
GLOSARIO = """GLOSARIO (usa estas palabras siempre con este significado):
- Noticia: lo que publica una fuente, tal cual (nota, comunicado, norma, convocatoria), con enlace y fecha. Una sola noticia no es una conclusión.
- Señal: un hecho que importa al turismo, armado a partir de una o varias noticias sobre lo mismo; tiene naturaleza (oportunidad, riesgo, mixta) y etapa. La mayoría se queda en el panel del equipo.
- Alerta: una señal que una persona del equipo confirmó y publicó (web pública o Telegram). Solo las señales en estado «publicada» son alertas. Un escenario nunca es alerta.
- Recomendación: lo que AVIA propone hacer ante una señal: acción concreta, para quién y qué falta comprobar. No es una orden ni un hecho.
Grado de certeza (cada señal trae uno; usa solo estas cuatro palabras):
- Confirmado: ya pasó o está pasando y lo respalda una fuente oficial, dos fuentes distintas o una persona del equipo.
- Convocado: anunciado por quien lo organiza para una fecha futura (paro, bloqueo, feria, convocatoria). Está anunciado; no se sabe si ocurrirá.
- Posible: hay indicios, pero nadie lo ha confirmado. Los escenarios siempre son «posible».
- Rumor: sin fuente identificable o solo redes sin respaldo.
No llames «alerta» a una señal sin publicar. La «alerta naranja/roja» del SENAMHI es el nombre del aviso de la fuente: cítalo como «aviso naranja del SENAMHI»."""


SIN_DATOS = """¡ATENCIÓN! NO SE PUDIERON CARGAR LOS DATOS DEL OBSERVATORIO (error técnico, no «cero señales»).
No digas que no hay señales, oportunidades ni riesgos. Di que ahora mismo no puedes consultar los datos del observatorio, que es un fallo técnico y que el panel puede mostrar información distinta. Los contadores de abajo NO son válidos: no los cites."""


# ── Formato de las respuestas (mejora 3 de la PoC; ver docs/respuestas-avia.md) ──
FORMATO = """CÓMO RESPONDER
A) Pregunta simple (un número, abrir una vista, un dato puntual): 1 a 3 frases, sin bloques.
B) Pregunta de análisis (situación, riesgos, oportunidades, una señal, un destino, un resumen): usa SIEMPRE estos bloques, en este orden, con estos títulos en markdown (#### Título):
#### Hechos
Lo que tiene certeza «confirmado» o «convocado» (regla 9). Cada hecho con su código (SEN-…), su certeza, la fuente y la fecha si están en los datos.
#### Pendiente de verificar
Lo que tiene certeza «posible» o «rumor». Di qué falta para confirmarlo (fuente oficial, segunda fuente o revisión de una persona).
#### Interpretación
Tu lectura de los hechos, marcada como interpretación («esto podría…»). Nunca la presentes como hecho.
#### Impacto turístico
A quién afecta (destinos, operadores, visitantes) y cómo. Si no hay datos para medirlo, dilo.
#### Escenarios
Qué podría pasar y bajo qué condición («si…, entonces…»). Son posibilidades, no predicciones seguras. Si no hay base para plantearlos, escribe «Sin datos suficientes para plantear escenarios».
#### Recomendación
Qué hacer, para quién, con quién verificarlo y qué falta saber antes de actuar (regla 10).

REGLAS
1. Un bloque sin contenido lleva «Sin datos» o «Nada pendiente»: no lo rellenes ni lo inventes, y no lo quites.
2. No fuerces cantidades. Si te piden 5 y hay 2, di «Solo hay 2» y da esas 2. Nunca completes con señales repetidas, viejas o inventadas.
3. Responde todas las partes de la pregunta. Si una parte no se puede responder con los datos, dilo en esa parte.
4. No mezcles hechos con hipótesis en la misma frase. Ante la duda, va en «Pendiente de verificar».
5. Usa solo los datos de este mensaje. Si algo no está, di «no lo tengo en los datos del observatorio».
6. Termina la respuesta: no la cortes a mitad de un bloque; si falta espacio, acorta cada bloque.
7. Puntuaciones: cada señal trae tres, siempre por su nombre y nunca un número suelto («0,95» no):
   - Fiabilidad de la evidencia (0-100, la calcula la base por fuentes oficiales, fuentes distintas y revisión humana; cita su nivel y por qué).
   - Probabilidad: solo si trae valor y justificación; si dice «sin datos», di «probabilidad: sin datos». No la estimes tú.
   - Impacto turístico (alto/medio/bajo) con su motivo.
   No las mezcles: una fuente muy fiable no hace que algo sea probable ni importante.
8. Trazabilidad: en «Hechos», cada hecho lleva fuente, enlace y fecha de PUBLICACIÓN de la fuente
   («SENAMHI, publicado 16/11 08:00, enlace»). Si la fuente no da fecha, di «la fuente no da fecha» y usa la
   de recogida diciendo que es de recogida. Si la fecha es «sin distinguir», dilo así. Cuando importe, añade
   cuándo la detectó AVIA y la última verificación de una persona; si no hay, «sin verificar por una persona».
   Nunca inventes una fecha ni un enlace.
9. Grado de certeza: cada hecho que cites lleva su certeza entre corchetes, con la palabra exacta que trae
   la señal en «certeza»: [confirmado], [convocado], [posible] o [rumor]. No la subas nunca: un «posible» no
   se cuenta como hecho y un «convocado» no es algo que ya pasó («la federación convocó un paro para el
   jueves», no «hay paro»). En «Hechos» solo van confirmados y convocados; posibles y rumores van en
   «Pendiente de verificar». Si la certeza trae «propuesto», AVIA la bajó por falta de fuentes: dilo.
10. Recomendaciones seguras: usa «recomendacion_segura» de cada señal. Cada recomendación dice qué hacer,
   para quién, con quién verificarlo («verificar_con») y «Falta saber:» con su lista; si la lista está vacía,
   no la inventes. NUNCA digas que una ruta, vuelo, aeropuerto, paso o destino está habilitado, operativo,
   transitable, abierto, normal o seguro, ni que «se puede viajar», salvo que una fuente oficial lo diga y
   «dato_oficial» sea de las últimas 24 h; entonces cita la fuente y la hora («según la ABC, a las 08:00»).
   Si trae «afirma_sin_verificar», no repitas lo que afirma: di que no está confirmado y con quién
   comprobarlo. Ante la duda, recomienda comprobar antes de viajar o de avisar a los visitantes.
11. Síntesis del día: si piden el resumen, la síntesis, el panorama o «qué pasa hoy» y abajo hay una SÍNTESIS DEL DÍA,
   no uses los seis bloques: responde con EXACTAMENTE tres, con estos títulos y en este orden:
   #### Qué pasa · #### Por qué importa · #### Qué vigilar
   Cópialos de la síntesis (ya viene armada por la base con los mismos contadores del panel): no añadas hechos
   que no estén, no cambies la certeza de ninguno y, si un bloque viene vacío, escribe «Sin novedades» en él.
   Empieza con la línea de totales y la hora de los datos. No fuerces tres elementos por bloque si hay menos.
12. El Pulso (índices «Atención a riesgos» y «Oportunidad» y el nivel de vigilancia) lo calcula el panel, no tú:
   no tienes su valor y NO lo inventes ni lo estimes. Si preguntan cómo se calcula, explica sus reglas y
   remite al botón «¿Cómo se calcula el Pulso?» del panel, que muestra la cuenta con los números de ahora:
   mide lo serias que son las señales, no cuántas hay; cada riesgo pesa prioridad (alta 1, media 0,5, baja 0,2)
   × respaldo (0,5 + 0,5 × fiabilidad de la evidencia) × etapa (confirmada o publicada 1, en verificación 0,85,
   detectada o en análisis 0,7); cada oportunidad pesa valor (45 % relevancia, 25 % novedad, 30 % fiabilidad)
   × etapa, y 0 si el plazo venció; índice = 100 × suma de pesos ÷ (señales + 2). Las mixtas y los escenarios
   cuentan la mitad. Niveles: menos de 25 normal o bajo, 25-49 vigilancia o moderado, 50-74 atención o alto,
   75 o más crítico o muy alto. Las fuentes caídas no entran en los índices.
13. Cambios desde ayer: si preguntan qué cambió, las novedades de hoy o cómo está «comparado con ayer» y abajo
   vienen CAMBIOS DESDE AYER, no uses los seis bloques: responde con estos cuatro, en este orden:
   #### Nuevas · #### Subieron de certeza · #### Bajaron de certeza · #### Resueltas
   Empieza con una línea con los cuatro conteos tal cual. Cada señal con su código y su certeza entre corchetes
   (en las que cambiaron: «de [posible] a [confirmado]»). Un bloque vacío lleva «Ninguna». Si trae AVISO de que
   aún no hay 24 h de registro, dilo en los bloques de certeza en lugar de poner «Ninguna». Si no vienen
   CAMBIOS DESDE AYER, di que no tienes la comparación y no la calcules tú.
14. Aeropuertos, vuelos y rutas: cuando hables de un aeropuerto, un vuelo, una ruta aérea o terrestre o un
   trayecto, separa SIEMPRE tres cosas y dilo con estas palabras, sin mezclarlas en la misma frase:
   - «Ya está»: el servicio, vuelo o conexión que funciona hoy según los datos (con su certeza y fuente).
   - «Va a llegar»: lo anunciado, previsto o en proyecto, con su fecha si la hay («convocado» o «posible»,
     nunca como si ya funcionara: «BoA anunció la ruta Santa Cruz–Lima para marzo», no «hay vuelo a Lima»).
   - «Quién depende de ese trayecto»: operadores, agencias, alojamientos o destinos que usan esa ruta y a los
     que afecta un cambio. Solo los que nombran los datos; si no hay, «no lo tengo en los datos del observatorio».
   Si de alguna de las tres no hay datos, dilo en esa parte en lugar de omitirla."""


# ── Contexto para el chat: misma lista y mismos números que el panel ─────────
_MAX_SENALES = 40   # señales que se pasan al modelo; los totales van aparte en «contadores»
_CAMPOS = ('id', 'titulo', 'resumen', 'naturaleza', 'categoria', 'estado', 'prioridad', 'certeza', 'recomendacion_segura', 'puntuaciones', 'trazabilidad',
           'deps', 'destinos', 'fecha_limite', 'evento_inicio', 'evento_fin', 'importancia', 'enlaces',
           'detectada', 'ultima_noticia', 'revision', 'escenario', 'soluciones')


def _compacta(x: dict) -> dict:
    c = {k: x[k] for k in _CAMPOS if x.get(k) not in (None, '', [], {})}
    t = c.get('trazabilidad')
    if isinstance(t, dict):   # hasta 3 fuentes por señal, para no gastar tokens
        c['trazabilidad'] = {**t, 'fuentes': [{k: f[k] for k in ('nombre', 'oficial', 'url', 'publicada', 'recogida', 'fecha', 'nota') if k in f}
                                               for f in (t.get('fuentes') or [])[:3] if isinstance(f, dict)]}
        c.pop('enlaces', None)
    r = c.get('recomendacion_segura')
    if isinstance(r, dict) and r.get('afirma_sin_verificar'):   # que el modelo no repita la frase sin verificar
        c['recomendacion_segura'] = {k: v for k, v in r.items() if k != 'original'}
        c.pop('soluciones', None)
    return c


def _sintesis_txt(s) -> str:
    """La síntesis del día que armó la base (db/generico/26_sintesis_dia.sql), en texto para el prompt."""
    if not isinstance(s, dict):
        return ''
    def lineas(items):
        out = []
        for i in items or []:
            if not isinstance(i, dict):
                continue
            partes = [i.get('codigo'), f"[{i['certeza']}]" if i.get('certeza') else None, i.get('titulo'),
                      i.get('texto') or i.get('motivo')]
            out.append('- ' + ' '.join(str(p) for p in partes if p))
        return '\n'.join(out) or 'Sin novedades'
    return (f"SÍNTESIS DEL DÍA (armada por la base; úsala para el resumen del día):\nTotales: {s.get('totales', '')}\n"
            f"Qué pasa:\n{lineas(s.get('que_pasa'))}\nPor qué importa:\n{lineas(s.get('por_que_importa'))}\n"
            f"Qué vigilar:\n{lineas(s.get('que_vigilar'))}")


# Preguntas por lo que cambió (mejora «vs ayer», db/generico/27_comparacion_dia.sql)
_RE_CAMBIOS = re.compile(r'qu[eé] (ha )?cambi|cambios|novedad|nuevo hoy|nuevas hoy|(comparad[oa]s?|frente|respecto|vs\.?) (a |con )?ayer|desde ayer|'
                         r'[uú]ltimas 24|qu[eé] hay de nuevo|qu[eé] pas[oó] (hoy|desde)', re.I)


def _comparacion_txt(c) -> str:
    """Lo que cambió en 24 h según la base (vigilante.comparacion_dia), en texto para el prompt."""
    if not isinstance(c, dict):
        return ('CAMBIOS DESDE AYER: la base aún no los calcula (falta ejecutar 27_comparacion_dia.sql). '
                'Si preguntan qué cambió, dilo así y no compares tú.')
    k = c.get('conteos') or {}
    def lineas(items, fmt):
        return '\n'.join('- ' + fmt(i) for i in (items or []) if isinstance(i, dict)) or '- Ninguna'
    nueva = lambda i: f"{i.get('codigo')} [{i.get('certeza')}] {i.get('titulo')}"
    cambio = lambda i: f"{i.get('codigo')} {i.get('titulo')}: de [{i.get('antes')}] a [{i.get('ahora')}]"
    como = {'cerrada': 'cerrada', 'descartada': 'descartada por el equipo', 'terminada': 'terminó su evento o plazo'}
    resuelta = lambda i: f"{i.get('codigo')} {i.get('titulo')} ({como.get(i.get('como'), i.get('como'))})"
    aviso = '' if c.get('comparable') else (
        '\nAVISO: aún no hay 24 h de registro de certezas, así que no se puede decir qué subió o bajó de certeza: dilo así.')
    return (f"CAMBIOS DESDE AYER (últimas 24 h, calculados por la base; no los recalcules):\n"
            f"Conteos: {k.get('nuevas', 0)} nuevas, {k.get('subieron', 0)} subieron de certeza, "
            f"{k.get('bajaron', 0)} bajaron de certeza, {k.get('resueltas', 0)} resueltas (las listas traen hasta 10).{aviso}\n"
            f"Señales nuevas:\n{lineas(c.get('senales_nuevas'), nueva)}\n"
            f"Subieron de certeza:\n{lineas(c.get('subieron_certeza'), cambio)}\n"
            f"Bajaron de certeza:\n{lineas(c.get('bajaron_certeza'), cambio)}\n"
            f"Resueltas:\n{lineas(c.get('resueltas'), resuelta)}")


def _desglose_verificadas(k: dict) -> str:
    """Las tres partes suman «verificadas» (39). Con una base anterior al 39 solo hay «2 o más fuentes»."""
    if k.get('verificadas_oficial') is None:
        return f"{k.get('verificadas_2_fuentes')} con 2 o más fuentes; las demás, por fuente oficial o con una sola fuente"
    partes = [(k.get('verificadas_2_fuentes'), 'con 2 o más fuentes'), (k.get('verificadas_oficial'), 'por fuente oficial'),
              (k.get('verificadas_una_fuente'), 'con una sola fuente')]
    return ' · '.join(f'{v} {t}' for v, t in partes if v) or 'ninguna'


def _fuentes_txt(k: dict) -> str:
    if k.get('fuentes_activas') is None:
        return ''
    return f"- Fuentes que AVIA vigila: {k.get('fuentes_activas')} activas ({k.get('fuentes_en_pausa') or 0} en pausa o propuestas, no cuentan)\n"


def _contar(activas: list, ctx: dict) -> dict:
    """Solo si la base aún no tiene el 21: mismas definiciones que vigilante.contadores()."""
    n = lambda f: sum(1 for x in activas if f(x))
    ver = ('confirmada', 'publicada'); pend = ('detectada', 'en_analisis', 'en_verificacion')
    return {
        'actualizado': ctx.get('generado'), 'senales_activas': len(activas),
        'oportunidades': n(lambda x: x.get('naturaleza') == 'oportunidad'),
        'riesgos': n(lambda x: x.get('naturaleza') == 'riesgo'),
        'mixtas': n(lambda x: x.get('naturaleza') == 'mixta'),
        'plazo_corto': '¿?', 'riesgos_altos': n(lambda x: x.get('naturaleza') == 'riesgo' and x.get('prioridad') == 'alta'),
        'verificadas': n(lambda x: x.get('estado') in ver),
        'verificadas_2_fuentes': n(lambda x: x.get('estado') in ver and len(x.get('enlaces') or []) >= 2),
        'por_verificar': n(lambda x: x.get('estado') in pend),
        'esperan_aprobacion': n(lambda x: x.get('estado') in pend and bool(x.get('revision'))),
        'alertas_publicadas': n(lambda x: x.get('estado') == 'publicada'),
        'noticias_24h': ctx.get('noticias_revisadas'),
    }


def _hora_bolivia(iso) -> str:
    try:
        from datetime import datetime, timedelta, timezone
        t = datetime.fromisoformat(str(iso).replace('Z', '+00:00'))
        return t.astimezone(timezone(timedelta(hours=-4))).strftime('%H:%M')
    except Exception:
        return '—'


# ── Rutas ─────────────────────────────────────────────────────────────────────

_RE_BLOQUE_JSON = re.compile(r'```[a-zA-Z]*\s*(\{.*?)(?:```|$)', re.S)
_RE_TEXTO = re.compile(r'"texto"\s*:\s*"((?:[^"\\]|\\.)*)', re.S)
_RE_COMANDO = re.compile(r'\{[^{}]*"tipo"\s*:\s*"[^"]+"[^{}]*\}', re.S)


def _json_suelto(s: str):
    """Intenta leer un objeto JSON tolerando saltos de línea dentro de las cadenas y texto sobrante al final."""
    try:
        return json.loads(s, strict=False)
    except (json.JSONDecodeError, ValueError):
        pass
    try:
        obj, _ = json.JSONDecoder(strict=False).raw_decode(s)
        return obj
    except (json.JSONDecodeError, ValueError):
        return None


def _separar_comandos(resp: str) -> dict:
    """Separa la respuesta del modelo en {texto, comandos}. El JSON nunca debe llegar a la pantalla:
    acepta el JSON solo, envuelto en ```json```, con texto antes o después, sin cerrar (cortado por
    max_tokens) o con saltos de línea crudos dentro de "texto"."""
    resp = (resp or '').strip()
    if '"texto"' not in resp:
        return {'texto': resp}
    m = _RE_BLOQUE_JSON.search(resp)
    if m:
        cand, fuera = m.group(1), (resp[:m.start()] + resp[m.end():]).strip()
    else:
        i = resp.find('{')
        cand, fuera = resp[i:], resp[:i].strip()
        j = cand.rfind('}')
        if j >= 0 and cand[j + 1:].strip():
            fuera = (fuera + '\n\n' + cand[j + 1:].strip()).strip()
            cand = cand[:j + 1]
    obj = _json_suelto(cand.strip())
    if isinstance(obj, dict) and 'texto' in obj:
        texto = str(obj.get('texto') or '').strip()
        comandos = obj.get('comandos')
    else:
        # JSON roto o cortado: se rescata el texto y las órdenes que se puedan leer
        mt = _RE_TEXTO.search(cand)
        texto = ''
        if mt:
            crudo = mt.group(1)
            try:
                texto = json.loads('"' + crudo + '"', strict=False)
            except (json.JSONDecodeError, ValueError):
                texto = crudo.replace('\\n', '\n').replace('\\"', '"')
        comandos = [c for c in (_json_suelto(x) for x in _RE_COMANDO.findall(cand)) if isinstance(c, dict)]
    comandos = [c for c in (comandos or []) if isinstance(c, dict) and c.get('tipo')] if isinstance(comandos, list) else []
    if not texto:
        texto = fuera or 'Listo.'
    out = {'texto': texto.strip()}
    if comandos:
        out['comandos'] = comandos
    return out


async def handle_chat(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.json_response({'error': 'unauthorized'}, status=401)

    jwt = _extract_jwt(request.headers.get('Cookie', ''))
    if not jwt:
        return web.json_response({'error': 'Se requiere sesión iniciada'}, status=401)

    body    = await request.json()
    mensajes: list = body.get('mensajes', [])
    rol: str       = body.get('rol', 'visor')

    async with aiohttp.ClientSession() as session:
        ctx     = await _get_context(session, jwt)
        # Misma lista y mismos números que el panel (db/generico/21_contadores_unicos.sql):
        # las señales activas son las visibles sin descartadas, y los totales salen de «contadores».
        todas   = [x for x in (ctx.get('senales', []) or []) if isinstance(x, dict)]
        activas = [x for x in todas if x.get('estado') != 'descartada']
        txt     = ' '.join(str(m.get('content', '')) for m in mensajes[-3:] if isinstance(m, dict))
        ultima  = next((str(m.get('content', '')) for m in reversed(mensajes) if isinstance(m, dict) and m.get('role') == 'user'), '')
        ids     = set(re.findall(r'SEN-\d+', txt))
        pedidas = [x for x in todas if str(x.get('id')) in ids]          # aunque esté descartada, si la nombran
        senales = pedidas + [_compacta(x) for x in activas[:_MAX_SENALES] if x not in pedidas]
        fuentes = [f for f in ctx.get('fuentes', []) if f.get('estado') not in ('activa', 'OK', None)][:5]
        sin_datos = not ctx
        k       = ctx.get('contadores') or _contar(activas, ctx)
        hora    = _hora_bolivia(k.get('actualizado') or ctx.get('generado'))

        system = f"""Eres AVIA, el asistente inteligente del Observatorio Turístico de Bolivia (ORBITA).
Ayudas al usuario ({rol}) a entender las señales de vigilancia y oportunidades turísticas.
Responde siempre en español, de forma concisa y útil.

{GLOSARIO}

{FORMATO}

{SIN_DATOS if sin_datos else ''}
DATOS ACTUALIZADOS A LAS {hora} (hora de Bolivia). Son los mismos números que muestra el panel.
CONTADORES (usa estos números tal cual; no cuentes tú la lista):
- Señales activas: {k.get('senales_activas')} (sin descartadas)
- Oportunidades: {k.get('oportunidades')} · Riesgos: {k.get('riesgos')} · Mixtas: {k.get('mixtas')}
- Oportunidades con plazo en menos de 15 días: {k.get('plazo_corto')}
- Riesgos de prioridad alta: {k.get('riesgos_altos')}
- Verificadas (confirmadas o publicadas): {k.get('verificadas')} ({_desglose_verificadas(k)})
{_fuentes_txt(k)}- Por verificar: {k.get('por_verificar')} ({k.get('esperan_aprobacion')} esperan aprobación de un analista)
- Alertas publicadas: {k.get('alertas_publicadas')}
- Noticias revisadas en 24 h: {k.get('noticias_24h')}

Cuando des un número total, cita la hora: «según los datos actualizados a las {hora}».
{"La lista de abajo solo trae " + str(len(senales)) + " de las " + str(k.get('senales_activas')) + " señales activas: para totales, usa los contadores." if len(activas) > _MAX_SENALES else ""}

{_sintesis_txt(ctx.get('sintesis_dia'))}

{_comparacion_txt(ctx.get('comparacion_dia')) if _RE_CAMBIOS.search(ultima) else ''}

SEÑALES ACTIVAS ({len(senales)}):
{json.dumps(senales, ensure_ascii=False)}

{("FUENTES CON PROBLEMAS: " + json.dumps(fuentes, ensure_ascii=False)) if fuentes else ""}

Puedes devolver comandos para mover la interfaz. En ese caso responde con un JSON:
{{"texto": "tu respuesta", "comandos": [{{"tipo": "abrir", "vista": "senales"}}]}}
Si usas comandos, responde SOLO con ese JSON: sin ```json```, sin texto antes ni después.
Si no hay comandos, responde solo con el texto (markdown, sin JSON)."""

        try:
            resp = await _deepseek(session, [{'role': 'system', 'content': system}] + mensajes, max_tokens=1100)
            # el modelo a veces devuelve JSON con comandos (suelto, en ```json```, cortado…): solo se muestra «texto»
            return web.json_response(_separar_comandos(resp))
        except Exception as e:
            print('CHAT ERROR', repr(e), flush=True)
            return web.json_response(
                {'texto': 'No pude contactar a la IA. Intenta de nuevo en un momento.'},
                status=500
            )


async def handle_analisis(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.json_response({'error': 'unauthorized'}, status=401)
    if not _extract_jwt(request.headers.get('Cookie', '')):
        return web.json_response({'error': 'Se requiere sesión iniciada'}, status=401)

    body      = await request.json()
    tipo      = body.get('tipo', 'panorama')
    territorio = body.get('territorio', 'Bolivia')
    pregunta  = body.get('pregunta', '')
    senales   = body.get('senales', [])

    prompt = f"""Eres AVIA, analista del Observatorio Turístico de Bolivia.
Genera un análisis de tipo "{tipo}" para "{territorio}".

{GLOSARIO}
{f"Pregunta específica: {pregunta}" if pregunta else ""}

SEÑALES ({len(senales)}):
{json.dumps(senales[:30], ensure_ascii=False)}

{FORMATO}

Es siempre una pregunta de análisis: usa los seis bloques. Markdown conciso para un funcionario de turismo, máximo 500 palabras."""

    async with aiohttp.ClientSession() as session:
        try:
            texto = await _deepseek(session, [{'role': 'user', 'content': prompt}], max_tokens=1400)
            return web.json_response({'texto': texto})
        except Exception as e:
            return web.json_response({'texto': f'Error en el análisis: {e}'}, status=500)


async def handle_evaluar(request: web.Request) -> web.Response:
    if not _check_auth(request):
        return web.json_response({'error': 'unauthorized'}, status=401)
    if not _extract_jwt(request.headers.get('Cookie', '')):
        return web.json_response({'error': 'Se requiere sesión iniciada'}, status=401)

    body          = await request.json()
    texto_noticia = body.get('texto', '')

    prompt = f"""Analiza esta noticia para el Observatorio Turístico de Bolivia.
Devuelve SOLO un objeto JSON con exactamente estos campos:
- naturaleza: "riesgo" | "oportunidad" | "mixta"
- categoria: "clima"|"salud"|"vial"|"conectividad"|"financiacion"|"eventos"|"normativa"|"mercado"
- departamentos: array de máx 3 nombres de departamentos bolivianos
- titulo: string (máx 90 caracteres)
- relevancia: número del 1 al 10
- novedad: número del 1 al 10
- confianza: número del 0 al 1
- importancia: string explicando por qué importa para el turismo
- acciones: array de exactamente 3 strings con acciones concretas
- verificar: string con cómo verificar la información

NOTICIA:
{texto_noticia[:2000]}

Devuelve SOLO el JSON, sin comentarios ni markdown."""

    async with aiohttp.ClientSession() as session:
        try:
            resp = await _deepseek(session, [{'role': 'user', 'content': prompt}], max_tokens=400)
            resp = resp.strip()
            # Limpiar posible bloque ```json ... ```
            if resp.startswith('```'):
                parts = resp.split('```')
                resp = parts[1].lstrip('json').strip() if len(parts) > 1 else resp
            return web.json_response(json.loads(resp))
        except json.JSONDecodeError:
            return web.json_response({'error': 'La IA devolvió un formato inesperado'}, status=500)
        except Exception as e:
            return web.json_response({'error': str(e)}, status=500)


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({'ok': True, 'service': 'avia-api', 'cliente': CLIENTE})


# ── Sesión: cookie sb-…-auth-token o cabecera X-Sb-Token, validada en Supabase Auth ──
_jwt_ok: dict = {}


async def _jwt_valido(jwt: str) -> bool:
    """Comprueba el JWT contra Supabase Auth (cache 60 s)."""
    c = _jwt_ok.get(jwt)
    if c and c[0] > time.time():
        return c[1]
    ok = False
    try:
        async with aiohttp.ClientSession() as ses:
            async with ses.get(f'{SB_URL}/auth/v1/user',
                               headers={'apikey': SB_KEY, 'Authorization': f'Bearer {jwt}'},
                               timeout=aiohttp.ClientTimeout(total=8)) as r:
                ok = (r.status == 200)
    except Exception:
        ok = False
    _jwt_ok[jwt] = (time.time() + 60, ok)
    return ok


@web.middleware
async def _auth_mw(request, handler):
    if request.method == 'POST':
        jwt = _extract_jwt(request.headers.get('Cookie', ''))
        if not jwt:
            tok = request.headers.get('X-Sb-Token', '').strip()
            if tok:
                jwt = tok
                ck = 'sb-web-auth-token=' + urllib.parse.quote(json.dumps({'access_token': tok}))
                request = request.clone(headers={**request.headers, 'Cookie': ck})
        if not jwt or not await _jwt_valido(jwt):
            return web.json_response({'error': 'Se requiere sesión válida'}, status=401)
    return await handler(request)


# ── App ───────────────────────────────────────────────────────────────────────
app = web.Application(middlewares=[_auth_mw])
app.router.add_post('/chat',    handle_chat)
app.router.add_post('/analisis', handle_analisis)
app.router.add_post('/evaluar', handle_evaluar)
app.router.add_get('/health',   handle_health)

if __name__ == '__main__':
    missing = [(k, v) for k, v in [
        ('SUPABASE_URL', SB_URL), ('SUPABASE_SERVICE_ROLE_KEY', SB_KEY), ('LLM_API_KEY', LLM_KEY)
    ] if not v]
    if missing:
        for k, _ in missing:
            print(f'ERROR: Falta {k} en ~/avia/supabase.env', file=sys.stderr)
        sys.exit(1)
    print(f'AVIA API arrancando en http://127.0.0.1:{PORT}  (cliente: {CLIENTE})')
    web.run_app(app, host='127.0.0.1', port=PORT, access_log=None)
