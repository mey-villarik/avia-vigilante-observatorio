// Logo del Vigilante animado para las esperas: una bolita de luz recorre el anillo tricolor
// dejando una estela corta y el satélite da vueltas por la órbita inclinada.
// Mismo dibujo que BrandMark (Shell.tsx); si alguien prefiere menos movimiento, queda quieto.
import { useEffect, useState } from 'react';

const C = 113.1; // 2·π·18, perímetro del anillo
const ESTELA = 14;

// Anillo: empieza arriba y gira en sentido horario, igual que los tercios de color.
const ANILLO = 'M22 4 A18 18 0 1 1 22 40 A18 18 0 1 1 22 4';
// Órbita: elipse 18×7 (se inclina con el grupo, como en el logo).
const ORBITA = 'M40 22 A18 7 0 1 1 4 22 A18 7 0 1 1 40 22';

function useMenosMovimiento() {
  const [menos, setMenos] = useState(() => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches);
  useEffect(() => {
    if (typeof matchMedia !== 'function') return;
    const mq = matchMedia('(prefers-reduced-motion: reduce)');
    const cambio = () => setMenos(mq.matches);
    mq.addEventListener('change', cambio);
    return () => mq.removeEventListener('change', cambio);
  }, []);
  return menos;
}

/** `parado`: deja el logo quieto (por ejemplo cuando la carga falló y ya no se espera nada). */
export function LogoCargando({ size = 72, className = '', parado = false }: { size?: number; className?: string; parado?: boolean }) {
  const quieto = useMenosMovimiento() || parado;
  return (
    <svg className={`logo-cargando ${className}`} width={size} height={size} viewBox="0 0 44 44" fill="none" aria-hidden="true">
      {/* anillo tricolor, más tenue para que destaque la bolita */}
      <g opacity=".55">
        <circle cx="22" cy="22" r="18" stroke="var(--bo-red)" strokeWidth="1.6" strokeDasharray="37.7 75.4" transform="rotate(-90 22 22)" />
        <circle cx="22" cy="22" r="18" stroke="var(--bo-yel)" strokeWidth="1.6" strokeDasharray="0 37.7 37.7 37.7" transform="rotate(-90 22 22)" />
        <circle cx="22" cy="22" r="18" stroke="var(--bo-grn)" strokeWidth="1.6" strokeDasharray="0 75.4 37.7 0" transform="rotate(-90 22 22)" />
      </g>

      {/* estela de luz que sigue a la bolita por el anillo */}
      {!quieto && (
        <circle cx="22" cy="22" r="18" stroke="currentColor" strokeWidth="2" strokeLinecap="round"
          strokeDasharray={`${ESTELA} ${C - ESTELA}`} transform="rotate(-90 22 22)" opacity=".85">
          <animate attributeName="stroke-dashoffset" from={ESTELA} to={ESTELA - C} dur="2.4s" repeatCount="indefinite" />
        </circle>
      )}

      {/* órbita inclinada con el satélite */}
      <g transform="rotate(-24 22 22)">
        <path d={ORBITA} stroke="currentColor" strokeWidth="1.1" opacity=".45" />
        {quieto ? (
          <circle cx="40" cy="22" r="2.2" fill="currentColor" />
        ) : (
          <circle r="2.2" fill="currentColor">
            <animateMotion dur="3.6s" repeatCount="indefinite" path={ORBITA} />
          </circle>
        )}
      </g>

      {/* núcleo con un latido suave */}
      <circle className={quieto ? undefined : 'lc-halo'} cx="22" cy="22" r="6.5" fill="currentColor" opacity=".18" />
      <circle cx="22" cy="22" r="3.4" fill="currentColor" />

      {/* la bolita que recorre el anillo */}
      {!quieto && (
        <circle r="2" fill="var(--ink)" className="lc-bola">
          <animateMotion dur="2.4s" repeatCount="indefinite" path={ANILLO} />
        </circle>
      )}
    </svg>
  );
}
