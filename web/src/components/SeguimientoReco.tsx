// En qué quedó la recomendación de una señal: pendiente, en curso, resuelta o sin efecto (SQL 50).
// Todos lo ven; analistas y administradores lo cambian. Para cerrarla hay que contar qué se hizo,
// quién actuó y qué pasó. No hay campo de responsable: la Dirección no tiene responsables por eje.
import { useState } from 'react';
import type { EstadoSeguimiento, Senal } from '../types';
import { useStore } from '../store';
import { ESTADOS_SEG, SEG_AYUDA, SEG_TXT, pideNota, seguimientoDe } from '../lib/seguimiento';
import { enBolivia } from '../lib/hora';
import { Icon } from './Icon';

export function SegTag({ s }: { s: Senal }) {
  const g = seguimientoDe(s);
  return <span className={`tag seg-${g.estado}`} title={SEG_AYUDA[g.estado]}>{SEG_TXT[g.estado]}</span>;
}

const PISTA: Record<EstadoSeguimiento, string> = {
  pendiente: 'Por qué vuelve a pendiente (opcional)',
  en_curso: 'Qué se está haciendo y quién (opcional)',
  resuelta: 'Qué se hizo, quién actuó y qué pasó',
  sin_efecto: 'Por qué no hizo falta, no se pudo o no sirvió',
};

export function SeguimientoReco({ s, compacta = false }: { s: Senal; compacta?: boolean }) {
  const role = useStore((st) => st.role);
  const followUp = useStore((st) => st.followUp);
  const g = seguimientoDe(s);
  const [nuevo, setNuevo] = useState<EstadoSeguimiento | null>(null);
  const [nota, setNota] = useState('');
  const [guardando, setGuardando] = useState(false);
  const puede = role !== 'visor';

  const guardar = async () => {
    if (!nuevo) return;
    setGuardando(true);
    const ok = await followUp(s.id, nuevo, nota);
    setGuardando(false);
    if (ok) { setNuevo(null); setNota(''); }
  };

  return (
    <div className={`seguimiento seg-b-${g.estado}${compacta ? ' compacta' : ''}`} aria-label="Seguimiento de la recomendación">
      <div className="seg-h">
        <span className="seg-lbl"><Icon name="check" />Seguimiento</span>
        <SegTag s={s} />
        {g.quien && <small className="seg-quien">{g.quien}{g.cuando ? ` · ${enBolivia(g.cuando, 'fechaHora')}` : ''}</small>}
      </div>
      {g.nota && <p className="seg-nota">{g.nota}</p>}
      {g.cambio_reco && g.recomendacion && (
        <p className="seg-aviso">AVIA cambió la recomendación desde entonces. Cuando se marcó, decía: «{g.recomendacion}».</p>
      )}
      {puede && (
        <div className="seg-acciones" role="group" aria-label="Cambiar el seguimiento">
          {ESTADOS_SEG.filter((e) => e !== g.estado).map((e) => (
            <button key={e} className={`btn sm ${nuevo === e ? 'on' : 'ghost'}`} title={SEG_AYUDA[e]}
              aria-pressed={nuevo === e} onClick={() => { setNuevo(nuevo === e ? null : e); setNota(''); }}>
              {SEG_TXT[e]}
            </button>
          ))}
        </div>
      )}
      {puede && nuevo && (
        <div className="seg-form">
          <textarea rows={compacta ? 2 : 3} value={nota} onChange={(e) => setNota(e.target.value)} placeholder={PISTA[nuevo]}
            aria-label={PISTA[nuevo]} autoFocus />
          <div className="seg-form-b">
            <button className="btn sm gold" disabled={guardando || (pideNota(nuevo) && !nota.trim())} onClick={() => void guardar()}>
              Marcar «{SEG_TXT[nuevo]}»
            </button>
            <button className="btn sm ghost" onClick={() => { setNuevo(null); setNota(''); }}>Cancelar</button>
          </div>
        </div>
      )}
      {!compacta && (g.historial?.length ?? 0) > 0 && (
        <details className="seg-hist">
          <summary>Qué se recomendó y qué se hizo ({g.historial!.length})</summary>
          <ol>
            {g.historial!.map((h, i) => (
              <li key={i}>
                <b>{SEG_TXT[h.de ?? 'pendiente']} → {SEG_TXT[h.a]}</b>
                <small> · {h.quien ?? 'Persona'}{h.cuando ? ` · ${enBolivia(h.cuando, 'fechaHora')}` : ''}</small>
                {h.recomendacion && <div className="seg-h-reco">Recomendación: {h.recomendacion}</div>}
                {h.nota && <div>{h.nota}</div>}
              </li>
            ))}
          </ol>
        </details>
      )}
    </div>
  );
}
