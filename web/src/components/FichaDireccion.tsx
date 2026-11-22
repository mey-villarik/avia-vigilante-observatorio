// Ficha fija para la Dirección (P1): lo primero que se ve de una señal es qué hacer, quién, hasta
// cuándo y cómo comprobarlo. Sale de vigilante.ficha_direccion() (49) o, sin ella, de lib/direccion.ts,
// que parte de la recomendación segura (25): nunca da por bueno algo sin dato oficial reciente.
import type { Senal } from '../types';
import { fichaDe } from '../lib/direccion';
import { Icon } from './Icon';

export function FichaDireccion({ s, compacta = false }: { s: Senal; compacta?: boolean }) {
  const f = fichaDe(s);
  return (
    <dl className={`ficha-dir${compacta ? ' compacta' : ''}${f.sin_verificar ? ' sinver' : ''}`} aria-label="Qué hacer">
      <div className="fd-accion">
        <dt><Icon name="decision" />Acción recomendada</dt>
        <dd>{f.accion}{f.afecta && !compacta ? <small className="fd-afecta">Afecta a {f.afecta}</small> : null}</dd>
      </div>
      <div>
        <dt><Icon name="clock" />Plazo</dt>
        <dd>{f.plazo}</dd>
      </div>
      <div>
        <dt><Icon name="shield" />Cómo verificar</dt>
        <dd>{f.verificar}</dd>
      </div>
    </dl>
  );
}
