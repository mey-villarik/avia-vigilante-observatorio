#!/usr/bin/env python3
"""AVIA Chat API – adaptador entre la web y DeepSeek con contexto de Supabase.

Protocolo (igual que el contrato en web/src/services/avia.ts):
  POST /chat     { mensajes, rol }                           -> { texto, comandos? }
  POST /analisis { tipo, territorio, pregunta?, senales }    -> { texto }
  POST /evaluar  { texto }                                   -> Evaluacion
  POST /saldo    {}                                          -> { disponible, saldos: [{moneda, total}] }
  GET  /health                                               -> { ok: true }

Cada llamada al modelo anota sus tokens en vigilante.system_logs (proceso avia-chat, avia-analisis o
avia-evaluar), como el clasificador; la web los suma con vigilante.uso_tokens() (db/generico/52).
/saldo pregunta a DeepSeek cuánto saldo le queda a la cuenta (incluye lo que gasta Hermes por su lado).

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

import asyncio, json, os, re, sys, time, urllib.parse
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
# USD por millón de tokens (opcional): si faltan, la base estima el coste con su tarifa (parámetros del 52)
LLM_PRECIO_ENTRADA = float(os.environ.get('LLM_PRECIO_ENTRADA') or 0)
LLM_PRECIO_SALIDA  = float(os.environ.get('LLM_PRECIO_SALIDA') or 0)
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


_tareas_uso: set = set()   # referencias a las anotaciones en curso (que no las recoja el recolector de basura)


async def _anotar_uso(proceso: str, uso: dict) -> None:
    """Guarda los tokens de una llamada en vigilante.system_logs (db/generico/52_uso_tokens.sql). Nunca falla hacia fuera."""
    te, ts = int(uso.get('prompt_tokens') or 0), int(uso.get('completion_tokens') or 0)
    if not (te or ts) or not SB_URL:
        return
    costo = round((te * LLM_PRECIO_ENTRADA + ts * LLM_PRECIO_SALIDA) / 1e6, 6) or None
    detalle = {'modelo': LLM_MODEL, 'tokens_entrada': te, 'tokens_salida': ts}
    if costo:
        detalle['costo_usd'] = costo
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as ses:
            await _supabase_post(ses, '/rest/v1/rpc/registrar_log', {
                'p_cliente': CLIENTE, 'p_proceso': proceso, 'p_nivel': 'info',
                'p_mensaje': f'Llamada al modelo: {te}+{ts} tokens', 'p_detalle': detalle,
                'p_costo_usd': costo, 'p_codigo_fuente': None})
    except Exception as e:  # noqa: BLE001 — la respuesta al usuario ya salió; solo se pierde la anotación
        print('USO NO ANOTADO', proceso, repr(e)[:200], flush=True)


async def _deepseek(session: aiohttp.ClientSession,
                    messages: list, max_tokens: int = 600, proceso: str = 'avia-chat') -> str:
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
    if isinstance(data.get('usage'), dict):
        t = asyncio.create_task(_anotar_uso(proceso, data['usage']))
        _tareas_uso.add(t)
        t.add_done_callback(_tareas_uso.discard)
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
- Verificada: señal confirmada o publicada que respalda una fuente oficial o 2 o más fuentes DISTINTAS (dos notas del mismo medio son una fuente). Cada señal trae «verificada»: true/false; usa ese dato. Una confirmada con una sola fuente no oficial es «confirmada sin verificar» y en la web pública sale «En verificación». No uses «verificada» con ningún otro sentido.
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
   Evolución: si abajo hay un bloque EVOLUCIÓN DEL PULSO, es de la base: cita esos valores tal cual (hace 7 y
   hace 30 días frente a ahora, y si mejora, empeora o está estable) y di «aproximado» en los reconstruidos.
   Si no hay bloque o un valor dice «sin datos», dilo así; no calcules tú la tendencia.
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
   Si de alguna de las tres no hay datos, dilo en esa parte en lugar de omitirla.
15. Plazos y cierres (CP1 y CP2): cada señal con plazo trae «cierre» con la fecha, los días que faltan y el
   texto ya calculados HOY por el sistema. Copia «cierre.texto» tal cual («cierra el 30/11/2026, en 8 días»).
   NUNCA cuentes tú los días, nunca los saques del resumen ni de la conversación anterior (pudieron
   cambiar desde entonces) y nunca des un número de días sin la fecha.
   La certeza del plazo va aparte de la certeza del evento: si «cierre.certeza_plazo» es «pendiente de
   verificar», escribe «plazo pendiente de verificar» y su motivo, aunque el evento sea [confirmado].
   Nunca llames «confirmado» a un plazo, cierre o fecha límite que no traiga certeza_plazo «confirmado».
16. Acciones en la pantalla (CP3): no puedes ver la pantalla. NUNCA escribas que ya abriste una vista, una
   señal o que aplicaste un filtro («abrí Señales», «ya filtré»). Si hace falta, manda la orden en «comandos»
   y escribe solo lo que encontraste en los datos; el panel añade debajo, él mismo, qué quedó abierto y los
   códigos de las señales que se ven. Si no mandas la orden, no digas que la vista está abierta.
17. Dirección (ejes, semáforo y qué hacer): si preguntan por la Dirección, el semáforo, un eje (movilidad,
   servicios esenciales, atención turística), un departamento, las decisiones de hoy o lo que viene, y abajo hay
   un bloque VISTA DIRECCIÓN, usa sus estados tal cual (Normal / Atención / Acción): no los recalcules ni los
   subas. Cada acción va con su ficha, con estas tres etiquetas y en este orden:
   «Acción recomendada · Plazo · Cómo verificar». Copia el plazo de la ficha. No asignes responsables ni
   inventes quién debe hacerlo: la Dirección no tiene responsables por eje. «Lo que viene» va por fecha de ocurrencia."""


# ── Plazos (CP1 y CP2; misma regla que vigilante.cierre() del 48 y web/src/lib/plazo.ts) ──
def _hoy_bolivia():
    from datetime import datetime, timedelta, timezone
    return datetime.now(timezone(timedelta(hours=-4))).date()


def _dias_para_cierre(fecha, hoy=None):
    """Días de calendario entre hoy (Bolivia) y el día de cierre: 0 hoy, 1 mañana, negativo si ya cerró."""
    from datetime import date
    try:
        d = date.fromisoformat(str(fecha)[:10])
    except (TypeError, ValueError):
        return None
    return (d - (hoy or _hoy_bolivia())).days


def _texto_cierre(fecha, hoy=None) -> str | None:
    n = _dias_para_cierre(fecha, hoy)
    if n is None:
        return None
    f = f'{str(fecha)[8:10]}/{str(fecha)[5:7]}/{str(fecha)[:4]}'
    if n < 0:
        return f'cerró el {f}'
    if n == 0:
        return f'cierra hoy ({f})'
    if n == 1:
        return f'cierra mañana ({f})'
    return f'cierra el {f}, en {n} días'


def _cierre(x: dict, hoy=None) -> dict | None:
    """Cierre de una señal calculado AHORA (no a la hora de la caché ni del día de la noticia).
    La certeza del plazo sale de la base (48); sin ella, «pendiente de verificar»: nunca se supone confirmada."""
    c = x.get('cierre') if isinstance(x.get('cierre'), dict) else {}
    fecha = str(c.get('fecha') or x.get('fecha_limite') or '')[:10]
    n = _dias_para_cierre(fecha, hoy)
    if n is None:
        return None
    ok = c.get('certeza') == 'confirmado'
    return {'fecha': fecha, 'dias_restantes': n, 'texto': _texto_cierre(fecha, hoy),
            'certeza_plazo': 'confirmado' if ok else 'pendiente de verificar',
            'motivo_plazo': c.get('motivo') or ('' if ok else 'Ninguna fuente primaria (oficial o quien convoca) da esta fecha todavía')}


# «quedan 12 días», «cierra en 5 días», «dentro de dos semanas»: el resumen se escribió el día de la noticia
_RE_RELATIVO = re.compile(r'\b(?:quedan|queda|faltan|falta|restan|resta|plazo\s+de|(?:cierra|vence|termina|finaliza|concluye|caduca)\s+en|'
                          r'dentro\s+de|en\s+los\s+pr[oó]ximos)\s+(?:solo\s+|s[oó]lo\s+|apenas\s+|unos?\s+)?'
                          r'(?:\d{1,3}|un|una|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|trece|catorce|quince|veinte|treinta)'
                          r'\s+(?:d[ií]as?|semanas?)(?:\s+h[aá]biles)?', re.I)


def _sin_relativos(t):
    return _RE_RELATIVO.sub('[plazo: ver «cierre»]', t) if isinstance(t, str) else t


_RE_DIAS = re.compile(r'\b(?P<pre>(?:quedan|queda|faltan|falta|restan|resta|cierra\s+en|vence\s+en|termina\s+en|en)\s+)(?P<n>\d{1,3})(?P<post>\s+d[ií]as?)\b', re.I)
_RE_PLAZO_CONF = re.compile(r'(?P<pre>\b(?:plazo|cierre|fecha\s+l[ií]mite|fecha\s+de\s+cierre)\b[^.\n]{0,40}?)\b(?P<c>confirmad[oa])\b(?:\s+por\s+[^,.;\n]+)?', re.I)


def _corregir_plazos(texto: str, senales: list) -> str:
    """Red de seguridad tras la respuesta del modelo. En cada línea que nombra UNA sola señal con plazo:
    los días que diga se cambian por los de hoy (CP1) y un plazo «confirmado» sin fuente primaria pasa a
    «pendiente de verificar» (CP2). Las líneas con varias señales no se tocan (no se sabe de cuál habla)."""
    cierres = {str(x.get('id')): x.get('cierre') for x in senales if isinstance(x, dict) and isinstance(x.get('cierre'), dict)}
    if not cierres or not isinstance(texto, str):
        return texto
    out = []
    for linea in texto.split('\n'):
        cods = set(re.findall(r'SEN-\d+', linea))
        c = cierres.get(next(iter(cods))) if len(cods) == 1 else None
        if c and c.get('dias_restantes') is not None:
            n = int(c['dias_restantes'])
            if n >= 0:
                linea = _RE_DIAS.sub(lambda m: f"{m.group('pre')}{n}{' día' if n == 1 else ' días'}", linea)
            if c.get('certeza_plazo') != 'confirmado':
                linea = _RE_PLAZO_CONF.sub(lambda m: m.group('pre') + 'pendiente de verificar', linea)
        out.append(linea)
    return '\n'.join(out)


# ── Contexto para el chat: misma lista y mismos números que el panel ─────────
_MAX_SENALES = 40   # señales que se pasan al modelo; los totales van aparte en «contadores»
_CAMPOS = ('id', 'titulo', 'resumen', 'naturaleza', 'categoria', 'estado', 'prioridad', 'certeza', 'recomendacion_segura', 'puntuaciones', 'trazabilidad',
           'deps', 'destinos', 'evento_inicio', 'evento_fin', 'importancia', 'enlaces',
           'detectada', 'ultima_noticia', 'revision', 'escenario', 'soluciones')


def _compacta(x: dict) -> dict:
    c = {k: x[k] for k in _CAMPOS if x.get(k) not in (None, '', [], {})}
    c['verificada'] = _verificada(x)   # antes de recortar la trazabilidad
    # CP1: el plazo va como fecha + días calculados ahora; las cuentas viejas del texto se tapan
    ci = _cierre(x)
    if ci:
        c['cierre'] = ci
    d = x.get('direccion')   # 49: eje y ficha «Acción · Plazo · Cómo verificar»
    if isinstance(d, dict):
        if d.get('eje'):
            c['eje'] = _EJE_TXT.get(d['eje'], d['eje'])
        if isinstance(d.get('ficha'), dict):
            c['ficha_direccion'] = {k: d['ficha'][k] for k in ('accion', 'plazo', 'verificar') if d['ficha'].get(k)}
    for k in ('titulo', 'resumen', 'importancia'):
        if k in c:
            c[k] = _sin_relativos(c[k])
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


# Preguntas por la tendencia del Pulso (DIANA 2.3, db/generico/46_pulso_evolucion.sql)
_RE_TENDENCIA = re.compile(r'pulso|tendencia|evoluci|mejora|empeora|estable|hace (7|siete|30|treinta) d[ií]as|[uú]ltim[oa]s? (semana|mes)', re.I)
_UMBRAL_ESTABLE = 5   # igual que UMBRAL_ESTABLE en web/src/lib/pulso.ts


def _pulso_evol_txt(e) -> str:
    """El Pulso de hoy frente al de hace 7 y 30 días (vigilante.pulso_evolucion), en texto para el prompt.
    Mismas reglas que tendencia() en web/src/lib/pulso.ts: menos de 5 puntos = estable; en riesgos subir es empeorar."""
    if not isinstance(e, dict) or not isinstance(e.get('hoy'), dict):
        return ('EVOLUCIÓN DEL PULSO: la base aún no la calcula (falta ejecutar 46_pulso_evolucion.sql). '
                'Si preguntan si mejora o empeora, dilo así y no lo estimes.')
    hoy = e['hoy']
    u = e.get('umbral_estable') or _UMBRAL_ESTABLE

    def comp(indice, nombre, antes, cuando):
        if not isinstance(antes, dict):
            return f'- {nombre}, frente a {cuando}: sin datos (aún no había señales)'
        a, h = antes.get(indice), hoy.get(indice)
        if a is None or h is None:
            return f'- {nombre}, frente a {cuando}: sin datos'
        d = h - a
        if abs(d) < u:
            sentido = 'estable'
        else:
            sentido = 'mejora' if (d > 0) == (indice == 'oportunidad') else 'empeora'
        aprox = ' (aproximado: reconstruido con el historial de las señales)' if antes.get('reconstruido') else ''
        return f"- {nombre}, frente a {cuando} ({antes.get('dia')}): de {a} a {h} ({d:+d}) → {sentido}{aprox}"

    lineas = []
    for indice, nombre in (('riesgo', 'Atención a riesgos'), ('oportunidad', 'Oportunidad')):
        lineas.append(comp(indice, nombre, e.get('hace_7'), 'hace 7 días'))
        lineas.append(comp(indice, nombre, e.get('hace_30'), 'hace 30 días'))
    return (f"EVOLUCIÓN DEL PULSO (calculada por la base con las mismas reglas que el panel; no la recalcules):\n"
            f"Ahora: atención a riesgos {hoy.get('riesgo')}/100, oportunidad {hoy.get('oportunidad')}/100, nivel {hoy.get('vigilancia')}.\n"
            + '\n'.join(lineas))


# Preguntas por lo que cambió (mejora «vs ayer», db/generico/27_comparacion_dia.sql)
_RE_CAMBIOS = re.compile(r'qu[eé] (ha )?cambi|cambios|novedad|nuevo hoy|nuevas hoy|(comparad[oa]s?|frente|respecto|vs\.?) (a |con )?ayer|desde ayer|'
                         r'[uú]ltimas 24|qu[eé] hay de nuevo|qu[eé] pas[oó] (hoy|desde)', re.I)


_RE_DIRECCION = re.compile(r'direcci[oó]n|sem[aá]foro|\bejes?\b|movilidad|servicios esenciales|atenci[oó]n tur[ií]stica|departament|'
                           r'decisi[oó]n|decisiones|qu[eé] hago|qu[eé] hacemos|lo que viene|pr[oó]xim[oa]s? (24|48|72|d[ií]as|semana|horas)|'
                           r'ma[nñ]ana|esta semana', re.I)
_ESTADO_TXT = {'normal': 'Normal', 'atencion': 'Atención', 'accion': 'Acción'}
_EJE_TXT = {'movilidad': 'Movilidad', 'servicios': 'Servicios esenciales', 'atencion': 'Atención turística'}


def _direccion_txt(d) -> str:
    """Bloque VISTA DIRECCIÓN de vigilante.direccion() (49): lo mismo que ve la pantalla Dirección."""
    if not isinstance(d, dict) or not d.get('ejes'):
        return ''
    l = [f"VISTA DIRECCIÓN (de la base, igual que la pantalla; hoy {d.get('hoy', '')}):",
         f"- Bolivia: {_ESTADO_TXT.get(d.get('bolivia'), d.get('bolivia'))}"]
    for e in d.get('ejes') or []:
        l.append(f"- {_EJE_TXT.get(e.get('eje'), e.get('eje'))}: {_ESTADO_TXT.get(e.get('estado'), e.get('estado'))} · "
                 f"{e.get('motivo')} · {e.get('para_actuar_hoy', 0)} para actuar hoy, {e.get('para_preparar', 0)} para preparar")
    dec = d.get('decisiones') or []
    l.append('DECISIONES DE HOY:' if dec else 'DECISIONES DE HOY: ninguna.')
    for i, x in enumerate(dec, 1):
        f = x.get('ficha') or {}
        l.append(f"{i}. {x.get('codigo')} {x.get('titulo')} [{x.get('certeza')}] — Acción recomendada: {f.get('accion')} · "
                 f"Plazo: {f.get('plazo')} · Cómo verificar: {f.get('verificar')}")
    deps = d.get('departamentos') or {}
    if deps:
        l.append('DEPARTAMENTOS: ' + ' | '.join(f"{k}: {_ESTADO_TXT.get(v.get('estado'), v.get('estado'))} ({v.get('motivo')})"
                                                + (f" → {v.get('recomendacion')}" if v.get('recomendacion') else '')
                                                for k, v in deps.items()))
    nac = d.get('nacionales') or []
    if nac:
        l.append('TODO EL PAÍS: ' + '; '.join(f"{x.get('codigo')} {x.get('titulo')} ({_ESTADO_TXT.get(x.get('estado'))})" for x in nac[:5]))
    viene = d.get('lo_que_viene') or []
    l.append('LO QUE VIENE (7 días, por fecha de ocurrencia):' if viene else 'LO QUE VIENE (7 días): nada con fecha.')
    for v in viene[:12]:
        l.append(f"- {v.get('fecha')} (en {v.get('dias')} días) · {v.get('tipo')} · {v.get('codigo')} {v.get('titulo')} [{v.get('certeza')}]")
    return '\n'.join(l)


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


def _verificada(x: dict) -> bool:
    """Regla única de «Verificada» (db/generico/40_verificada_unica.sql y web/src/lib/verificada.ts):
    confirmada o publicada, no escenario, y fuente oficial o 2 o más fuentes distintas."""
    if x.get('estado') not in ('confirmada', 'publicada') or x.get('escenario'):
        return False
    f = ((x.get('puntuaciones') or {}).get('fiabilidad') or {}) if isinstance(x.get('puntuaciones'), dict) else {}
    if f:
        return bool(f.get('oficial')) or (f.get('fuentes') or 0) >= 2
    t = x.get('trazabilidad') if isinstance(x.get('trazabilidad'), dict) else {}
    fu = [z for z in (t.get('fuentes') or []) if isinstance(z, dict)]
    if fu:
        return any(z.get('oficial') for z in fu) or len({z.get('nombre') or z.get('url') for z in fu}) >= 2
    return len(x.get('enlaces') or []) >= 2


def _al_dia(k: dict, activas: list) -> dict:
    """Pasa los contadores de una base anterior al 40 a la regla única, igual que hace la web:
    con el 39 las de una sola fuente salen de «verificadas»; sin el 39 se cuentan aquí."""
    if k.get('confirmadas_sin_verificar') is not None:
        return k
    k = dict(k)
    if k.get('verificadas_oficial') is not None and k.get('verificadas_una_fuente') is not None:
        k['confirmadas_sin_verificar'] = k['verificadas_una_fuente']
        k['verificadas'] = (k.get('verificadas_2_fuentes') or 0) + (k.get('verificadas_oficial') or 0)
    else:
        ver = [x for x in activas if _verificada(x)]
        k['verificadas'] = len(ver)
        k['verificadas_2_fuentes'] = None
        k['verificadas_oficial'] = None
        k['confirmadas_sin_verificar'] = sum(1 for x in activas if x.get('estado') in ('confirmada', 'publicada') and not _verificada(x))
    k['verificadas_una_fuente'] = 0
    return k


def _desglose_verificadas(k: dict) -> str:
    """«55 por fuente oficial · 2 con 2 o más fuentes» (las dos suman «verificadas»)."""
    if k.get('verificadas_oficial') is None:
        return 'por fuente oficial o con 2 o más fuentes distintas'
    partes = [(k.get('verificadas_oficial'), 'por fuente oficial'), (k.get('verificadas_2_fuentes'), 'con 2 o más fuentes distintas')]
    return ' · '.join(f'{v} {t}' for v, t in partes if v) or 'ninguna'


def _cifras_fuentes(fuentes: list) -> dict:
    """Misma regla que web/src/lib/contadores.ts → cifrasFuentes() y vigilante.contadores() (41):
    activas = no MANT; leídas = OK o WARN; sin leer = el resto de las activas (CRIT o UNKNOWN)."""
    act = [f for f in fuentes if isinstance(f, dict) and f.get('estado') != 'MANT']
    leidas = sum(1 for f in act if f.get('estado') in ('OK', 'WARN'))
    return {'fuentes_activas': len(act), 'fuentes_leidas': leidas, 'fuentes_sin_leer': len(act) - leidas,
            'fuentes_en_pausa': sum(1 for f in fuentes if isinstance(f, dict) and f.get('estado') == 'MANT')}


def _fuentes_txt(k: dict) -> str:
    """«28 de 33 fuentes leídas · 5 sin leer»: la misma cifra que el encabezado, el Pulso y la pestaña Fuentes."""
    if k.get('fuentes_activas') is None:
        return ''
    pausa = k.get('fuentes_en_pausa') or 0
    extra = f" ({pausa} en pausa o propuestas, no cuentan)" if pausa else ''
    if k.get('fuentes_leidas') is None:
        return f"- Fuentes que AVIA vigila: {k.get('fuentes_activas')} activas{extra}\n"
    return (f"- Fuentes que AVIA vigila: {k.get('fuentes_leidas')} de {k.get('fuentes_activas')} leídas · "
            f"{k.get('fuentes_sin_leer')} sin leer{extra}. Leída = su última comprobación dio OK o AVISO; "
            "sin leer = CRÍTICO o todavía sin comprobar\n")


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
        'verificadas': n(_verificada),
        'confirmadas_sin_verificar': n(lambda x: x.get('estado') in ver and not _verificada(x)),
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
        # las que nombra el usuario también van compactas: así llevan su «cierre» de hoy (CP1)
        senales = [_compacta(x) for x in pedidas] + [_compacta(x) for x in activas[:_MAX_SENALES] if x not in pedidas]
        fuentes = [f for f in ctx.get('fuentes', []) if f.get('estado') not in ('activa', 'OK', None)][:5]
        sin_datos = not ctx
        k       = _al_dia(ctx.get('contadores') or _contar(activas, ctx), activas)
        if k.get('fuentes_leidas') is None and ctx.get('fuentes'):
            # base anterior al 41: las cuatro cifras de la misma lista que cuenta la web, para que cuadren entre sí
            k = {**k, **_cifras_fuentes(ctx['fuentes'])}
        hora    = _hora_bolivia(k.get('actualizado') or ctx.get('generado'))

        system = f"""Eres AVIA, el asistente inteligente del Observatorio Turístico de Bolivia (ORBITA).
Ayudas al usuario ({rol}) a entender las señales de vigilancia y oportunidades turísticas.
Responde siempre en español, de forma concisa y útil.

{GLOSARIO}

{FORMATO}

{SIN_DATOS if sin_datos else ''}
HOY ES {_hoy_bolivia().strftime('%d/%m/%Y')} en Bolivia. Los días hasta cada cierre ya vienen calculados en «cierre» (regla 15).
DATOS ACTUALIZADOS A LAS {hora} (hora de Bolivia). Son los mismos números que muestra el panel.
CONTADORES (usa estos números tal cual; no cuentes tú la lista):
- Señales activas: {k.get('senales_activas')} (sin descartadas)
- Oportunidades: {k.get('oportunidades')} · Riesgos: {k.get('riesgos')} · Mixtas: {k.get('mixtas')}
- Oportunidades con plazo en menos de 15 días: {k.get('plazo_corto')}
- Riesgos de prioridad alta: {k.get('riesgos_altos')}
- Verificadas (confirmadas o publicadas con fuente oficial o 2 o más fuentes distintas): {k.get('verificadas')} ({_desglose_verificadas(k)})
- Confirmadas sin verificar (una sola fuente no oficial; NO las llames verificadas): {k.get('confirmadas_sin_verificar') or 0}
{_fuentes_txt(k)}- Por verificar: {k.get('por_verificar')} ({k.get('esperan_aprobacion')} esperan aprobación de un analista)
- Alertas publicadas: {k.get('alertas_publicadas')}
- Noticias revisadas en 24 h: {k.get('noticias_24h')}

Cuando des un número total, cita la hora: «según los datos actualizados a las {hora}».
{"La lista de abajo solo trae " + str(len(senales)) + " de las " + str(k.get('senales_activas')) + " señales activas: para totales, usa los contadores." if len(activas) > _MAX_SENALES else ""}

{_sintesis_txt(ctx.get('sintesis_dia'))}

{_comparacion_txt(ctx.get('comparacion_dia')) if _RE_CAMBIOS.search(ultima) else ''}

{_pulso_evol_txt(ctx.get('pulso_evolucion')) if _RE_TENDENCIA.search(ultima) else ''}

{_direccion_txt(ctx.get('direccion')) if _RE_DIRECCION.search(ultima) else ''}

SEÑALES ACTIVAS ({len(senales)}):
{json.dumps(senales, ensure_ascii=False)}

{("FUENTES CON PROBLEMAS: " + json.dumps(fuentes, ensure_ascii=False)) if fuentes else ""}

Puedes devolver comandos para mover la interfaz. En ese caso responde con un JSON:
{{"texto": "tu respuesta", "comandos": [{{"tipo": "abrir", "vista": "senales"}}]}}
Para abrir Señales filtrada usa «filtro» (solo estas claves): {{"tipo": "abrir", "vista": "senales", "filtro": {{"naturaleza": "riesgo" | "oportunidad" | "mixta", "departamento": "La Paz", "texto": "bloqueo", "revisar": true}}}}.
Vistas: direccion, panorama, mapa, fuentes, senales, oportunidades, internacional, analisis, bitacora. Para una señal: {{"tipo": "abrir", "senal": "SEN-0027"}}.
En «texto» NO digas que ya lo abriste ni que el filtro está aplicado (regla 16): el panel lo confirma solo, con los códigos que se ven.
Si usas comandos, responde SOLO con ese JSON: sin ```json```, sin texto antes ni después.
Si no hay comandos, responde solo con el texto (markdown, sin JSON)."""

        try:
            resp = await _deepseek(session, [{'role': 'system', 'content': system}] + mensajes, max_tokens=1100)
            # el modelo a veces devuelve JSON con comandos (suelto, en ```json```, cortado…): solo se muestra «texto»
            out = _separar_comandos(resp)
            out['texto'] = _corregir_plazos(out['texto'], senales)   # CP1 y CP2: días de hoy y certeza del plazo
            return web.json_response(out)
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
            texto = await _deepseek(session, [{'role': 'user', 'content': prompt}], max_tokens=1400, proceso='avia-analisis')
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
            resp = await _deepseek(session, [{'role': 'user', 'content': prompt}], max_tokens=400, proceso='avia-evaluar')
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


_saldo_cache: list = [0.0, None]   # [hasta cuándo vale, respuesta]


async def handle_saldo(request: web.Request) -> web.Response:
    """Saldo que le queda a la cuenta del modelo (DeepSeek: GET /user/balance). Cache de 5 minutos.
    Es el único dato que incluye lo que gasta Hermes por su lado, que no pasa por esta API."""
    if not _check_auth(request):
        return web.json_response({'error': 'unauthorized'}, status=401)
    if _saldo_cache[1] is not None and _saldo_cache[0] > time.time():
        return web.json_response(_saldo_cache[1])
    if 'deepseek' not in LLM_BASE:
        return web.json_response({'disponible': None, 'motivo': 'El proveedor del modelo no informa del saldo'})
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as ses:
            async with ses.get(f'{LLM_BASE}/user/balance', headers={'Authorization': f'Bearer {LLM_KEY}',
                                                                     'Accept': 'application/json'}) as r:
                data = await r.json(content_type=None)
        if not isinstance(data, dict) or 'balance_infos' not in data:
            raise RuntimeError(f'HTTP {r.status}: {str(data)[:200]}')
        out = {'disponible': bool(data.get('is_available')), 'proveedor': 'DeepSeek',
               'saldos': [{'moneda': b.get('currency'), 'total': float(b.get('total_balance') or 0),
                           'regalado': float(b.get('granted_balance') or 0),
                           'recargado': float(b.get('topped_up_balance') or 0)}
                          for b in data.get('balance_infos') or [] if isinstance(b, dict)],
               'consultado': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
        _saldo_cache[:] = [time.time() + 300, out]
        return web.json_response(out)
    except Exception as e:  # noqa: BLE001
        print('SALDO ERROR', repr(e)[:200], flush=True)
        return web.json_response({'disponible': None, 'motivo': 'No se pudo consultar el saldo del modelo'}, status=502)


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
app.router.add_post('/saldo',   handle_saldo)
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
