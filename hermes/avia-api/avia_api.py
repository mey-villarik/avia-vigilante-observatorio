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

_CTX_TTL  = 120   # segundos que se cachea el contexto de Supabase
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
        timeout=aiohttp.ClientTimeout(total=30),
    ) as r:
        data = await r.json()
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
            return ctx
    except Exception:
        pass
    return {}


# ── Rutas ─────────────────────────────────────────────────────────────────────

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
        senales = ctx.get('senales', [])[:10]
        fuentes = [f for f in ctx.get('fuentes', []) if f.get('estado') not in ('activa', None)][:5]

        system = f"""Eres AVIA, el asistente inteligente del Observatorio Turístico de Bolivia (ORBITA).
Ayudas al usuario ({rol}) a entender las señales de vigilancia y oportunidades turísticas.
Responde siempre en español, de forma concisa y útil.

SEÑALES ACTIVAS RECIENTES ({len(senales)}):
{json.dumps(senales, ensure_ascii=False)}

{("FUENTES CON PROBLEMAS: " + json.dumps(fuentes, ensure_ascii=False)) if fuentes else ""}

Puedes devolver comandos para mover la interfaz. En ese caso responde con un JSON:
{{"texto": "tu respuesta", "comandos": [{{"tipo": "abrir", "vista": "senales"}}]}}
Si no hay comandos, responde solo con texto plano."""

        try:
            resp = await _deepseek(session, [{'role': 'system', 'content': system}] + mensajes, max_tokens=400)
            resp = resp.strip()
            # El modelo a veces devuelve JSON con comandos
            if resp.startswith('{'):
                try:
                    parsed = json.loads(resp)
                    if isinstance(parsed, dict) and 'texto' in parsed:
                        return web.json_response(parsed)
                except (json.JSONDecodeError, ValueError):
                    pass
            return web.json_response({'texto': resp})
        except Exception as e:
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
{f"Pregunta específica: {pregunta}" if pregunta else ""}

SEÑALES ({len(senales)}):
{json.dumps(senales[:30], ensure_ascii=False)}

Responde en markdown conciso para un funcionario de turismo. Máximo 400 palabras."""

    async with aiohttp.ClientSession() as session:
        try:
            texto = await _deepseek(session, [{'role': 'user', 'content': prompt}], max_tokens=800)
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


# ── App ───────────────────────────────────────────────────────────────────────
app = web.Application()
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
