// Asistente "Pregunta a AVIA": botón flotante y ventana acoplable / movible.
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { useStore } from '../store';
import { aviaConectado } from '../services/avia';
import { CHIPS, sendChat, useChat } from '../services/chat';

const Avatar = () => (
  <svg className="av" viewBox="0 0 32 32" aria-hidden="true">
    <circle cx="16" cy="16" r="15" fill="var(--opp-soft)" stroke="var(--opp)" />
    <path d="M10 22 16 10l6 12M12.2 17.6h7.6" stroke="var(--opp)" strokeWidth="2" strokeLinecap="round" />
  </svg>
);

export function Chat() {
  const open = useStore((s) => s.chatOpen);
  const docked = useStore((s) => s.docked);
  const msgs = useStore((s) => s.chat);
  const busy = useStore((s) => s.chatBusy);
  const setPrefs = useStore((s) => s.setPrefs);
  const { openChat, closeChat, resetChat } = useChat();
  const [txt, setTxt] = useState('');
  const [pos, setPos] = useState<{ left: number; top: number; height: number } | null>(null);
  const log = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const drag = useRef<{ sx: number; sy: number; ox: number; oy: number } | null>(null);

  useEffect(() => { if (log.current) log.current.scrollTop = 1e9; }, [msgs]);
  useEffect(() => { if (open) input.current?.focus(); }, [open]);

  const send = (e?: FormEvent) => { e?.preventDefault(); const t = txt; setTxt(''); void sendChat(t); };
  const showChips = msgs.length <= 1;

  if (!open) {
    return (
      <button className="chat-fab" aria-label="Abrir el asistente AVIA" onClick={() => openChat()}>
        <Avatar /><span className="fl">Pregunta a AVIA</span>
      </button>
    );
  }

  return (
    <section ref={box} className={`chat ${docked ? 'docked' : ''}`} aria-label="Asistente AVIA"
      style={!docked && pos ? { left: pos.left, top: pos.top, height: pos.height, right: 'auto', bottom: 'auto' } : undefined}>
      <div className="chat-h"
        onPointerDown={(e) => {
          if ((e.target as HTMLElement).closest('button') || docked || !box.current) return;
          const r = box.current.getBoundingClientRect();
          drag.current = { sx: e.clientX, sy: e.clientY, ox: r.left, oy: r.top };
          e.currentTarget.setPointerCapture(e.pointerId);
        }}
        onPointerMove={(e) => {
          const d = drag.current; if (!d || !box.current) return;
          const left = Math.max(0, Math.min(innerWidth - box.current.offsetWidth, d.ox + e.clientX - d.sx));
          const top = Math.max(0, Math.min(innerHeight - 60, d.oy + e.clientY - d.sy));
          setPos({ left, top, height: Math.min(640, innerHeight - top - 16) });
        }}
        onPointerUp={() => { drag.current = null; }}>
        <Avatar />
        <div><b>AVIA</b><small>{aviaConectado ? 'Conectada · datos de ejemplo' : 'Modo local (sin IA) · datos de ejemplo'}</small></div>
        <div className="tools">
          <button className="icon-btn" aria-label="Acoplar o soltar" title="Acoplar a la derecha / flotante" onClick={() => { setPos(null); setPrefs({ docked: !docked }); }}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><rect x="3.5" y="4.5" width="17" height="15" rx="2" /><path d="M14.5 4.5v15" /></svg>
          </button>
          <button className="icon-btn" aria-label="Nueva conversación" title="Nueva conversación" onClick={resetChat}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4" /></svg>
          </button>
          <button className="icon-btn" aria-label="Cerrar asistente" title="Cerrar" onClick={closeChat}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="m6 6 12 12M18 6 6 18" /></svg>
          </button>
        </div>
      </div>
      <div className="chat-log" ref={log} aria-live="polite">
        {msgs.map((m) => <div key={m.id} className={`msg ${m.role}`}>{m.text}{m.act && <span className="act">{m.act}</span>}</div>)}
      </div>
      <div className="chips">
        {showChips && CHIPS.map((c) => <button key={c} className="chip" onClick={() => void sendChat(c)}>{c}</button>)}
      </div>
      <div className="mode-note">
        {aviaConectado ? 'AVIA puede consultar señales y fuentes, abrir vistas y cambiar el tablero.' : 'Respuestas por reglas. Configura VITE_AVIA_API_URL para hablar con la IA.'}
      </div>
      <form className="chat-f" onSubmit={send}>
        <label className="sr" htmlFor="chatIn">Mensaje para AVIA</label>
        <textarea ref={input} id="chatIn" rows={1} placeholder="Pregunta, pide un análisis o di «añade el mapa»…" value={txt}
          onChange={(e) => { setTxt(e.target.value); e.target.style.height = 'auto'; e.target.style.height = Math.min(120, e.target.scrollHeight) + 'px'; }}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }} />
        <button className="btn primary" type="submit" disabled={busy}>Enviar</button>
      </form>
    </section>
  );
}
