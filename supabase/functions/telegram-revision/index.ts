// Función de Supabase (Edge Function) «telegram-revision».
// Recibe los clics en los botones «Aprobar y publicar» / «Rechazar» que el bot pone en el
// grupo privado de analistas (db/generico/18_aprobacion_analista.sql, avisar_analistas()).
//
// Telegram la llama como webhook. Comprueba:
//   1. la cabecera X-Telegram-Bot-Api-Secret-Token (la clave que se da en setWebhook);
//   2. en la base (decidir_senal_telegram): que el botón viene del grupo de analistas
//      configurado y que quien pulsa es analista o administrador activo
//      (vigilante.users.telegram_chat_id = su id de Telegram).
// Después actualiza el mensaje: dice quién decidió y quita los botones.
//
// Secretos de la función (supabase secrets set ...):
//   TELEGRAM_BOT_TOKEN       el mismo token que telegram_bot_token del Vault
//   TELEGRAM_WEBHOOK_SECRET  una clave larga inventada (solo letras, números, _ y -)
// SUPABASE_URL y la service_role los da Supabase.
//
// Despliegue (sin JWT: quien llama es Telegram, no un usuario con sesión):
//   supabase functions deploy telegram-revision --no-verify-jwt --project-ref <ref>
// Guía: docs/aprobacion-analista.md
import { createClient } from 'npm:@supabase/supabase-js@2.99.3';

/** Lee una clave de las variables que da Supabase (formato clásico o claves nuevas sb_secret_). */
function leerClave(...nombres: string[]): string | undefined {
  for (const n of nombres) {
    const v = Deno.env.get(n)?.trim();
    if (!v) continue;
    if (!v.startsWith('{') && !v.startsWith('[')) return v;
    try {
      const j = JSON.parse(v);
      const vals = Array.isArray(j) ? j : Object.values(j);
      const primera = vals.find((x) => typeof x === 'string' && x);
      if (primera) return primera as string;
    } catch { /* no es JSON */ }
  }
  return undefined;
}

const html = (t: string) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

async function telegram(token: string, metodo: string, cuerpo: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${token}/${metodo}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cuerpo),
  });
  if (!r.ok) console.error(`Telegram ${metodo}: HTTP ${r.status} ${await r.text()}`);
}

interface CallbackQuery {
  id: string;
  from: { id: number; first_name?: string };
  data?: string;
  message?: { message_id: number; chat: { id: number }; text?: string };
}

Deno.serve(async (req) => {
  // Telegram siempre recibe 200 (si no, reintenta); los fallos van al registro de la función.
  const ok = () => new Response('ok');
  if (req.method !== 'POST') return ok();

  const secreto = Deno.env.get('TELEGRAM_WEBHOOK_SECRET');
  if (!secreto || req.headers.get('x-telegram-bot-api-secret-token') !== secreto) {
    return new Response('forbidden', { status: 403 });
  }
  const token = Deno.env.get('TELEGRAM_BOT_TOKEN');
  const url = Deno.env.get('SUPABASE_URL');
  const service = leerClave('SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_SECRET_KEYS', 'SUPABASE_SECRET_KEY');
  if (!token || !url || !service) {
    console.error('Faltan TELEGRAM_BOT_TOKEN, SUPABASE_URL o la service_role');
    return ok();
  }

  let cq: CallbackQuery | undefined;
  try { cq = (await req.json())?.callback_query; } catch { return ok(); }
  if (!cq?.data || !cq.message) return ok();

  const m = /^(ap|re):(\d+)$/.exec(cq.data);
  if (!m) { await telegram(token, 'answerCallbackQuery', { callback_query_id: cq.id }); return ok(); }
  const aprobar = m[1] === 'ap';

  const db = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await db.schema('vigilante').rpc('decidir_senal_telegram', {
    p_signal_id: Number(m[2]), p_telegram_user: cq.from.id, p_chat: String(cq.message.chat.id), p_aprobar: aprobar,
  });
  const r = (data ?? {}) as { ok?: boolean; mensaje?: string; codigo?: string };
  const aviso = error ? `No se pudo guardar: ${error.message}` : (r.mensaje ?? 'Hecho');

  // respuesta emergente solo para quien pulsó
  await telegram(token, 'answerCallbackQuery', { callback_query_id: cq.id, text: aviso.slice(0, 190), show_alert: !r.ok });

  // si quedó decidida (ahora o antes), el mensaje lo dice y pierde los botones
  if (!error && (r.ok || /^Ya estaba decidida/.test(aviso))) {
    const titulo = (cq.message.text ?? '').split('\n').find((l, i) => i > 0 && l.trim()) ?? r.codigo ?? '';
    await telegram(token, 'editMessageText', {
      chat_id: cq.message.chat.id, message_id: cq.message.message_id, parse_mode: 'HTML',
      disable_web_page_preview: true,
      text: `<b>${html(titulo)}</b>\n${r.ok ? (aprobar ? '✅ ' : '✖️ ') : ''}${html(aviso)}`,
    });
  }
  return ok();
});
