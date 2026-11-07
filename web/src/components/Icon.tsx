// Iconos de línea (24×24). Para añadir uno, añade su trazado aquí.
export const ICONS: Record<string, string> = {
  usuario:'<circle cx="12" cy="8" r="3.8"/><path d="M4.5 20c.8-3.8 3.8-6 7.5-6s6.7 2.2 7.5 6"/>',
  equipo:'<circle cx="9" cy="8.5" r="3.2"/><path d="M3 19.5c.6-3.3 3-5.2 6-5.2s5.4 1.9 6 5.2"/><path d="M15.5 5.6a3.1 3.1 0 0 1 0 5.8M17.5 14.6c2 .6 3.2 2.3 3.5 4.9"/>',
  candado:'<rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>',
  salir:'<path d="M14 4.5H6.5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2H14"/><path d="m16 8 4 4-4 4M20 12H10"/>',
  panorama:'<rect x="3.5" y="3.5" width="7" height="8" rx="1.5"/><rect x="13.5" y="3.5" width="7" height="5" rx="1.5"/><rect x="13.5" y="11.5" width="7" height="9" rx="1.5"/><rect x="3.5" y="14.5" width="7" height="6" rx="1.5"/>',
  fuentes:'<circle cx="12" cy="12" r="2"/><path d="M7.8 16.2a6 6 0 0 1 0-8.4M16.2 7.8a6 6 0 0 1 0 8.4M5 19a10 10 0 0 1 0-14M19 5a10 10 0 0 1 0 14"/>',
  senales:'<path d="M3 12h4l2.5-6 5 12 2.5-6h4"/>',
  oportunidades:'<path d="M12 3.5 14.6 9l6 .7-4.5 4.1 1.2 5.9L12 16.8 6.7 19.7l1.2-5.9L3.4 9.7l6-.7Z"/>',
  analisis:'<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
  bitacora:'<path d="M6 3.5h10l3 3v14H6z"/><path d="M9.5 9h6M9.5 13h6M9.5 17h4"/>',
  mapa:'<path d="m9 4-5.5 2v14L9 18l6 2 5.5-2V4L15 6Z"/><path d="M9 4v14M15 6v14"/>',
  pulso:'<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3 2"/>',
  cadena:'<path d="M9.5 14.5 14.5 9.5"/><path d="M11 6.5 12.6 5a3.9 3.9 0 0 1 5.5 5.5L16.5 12M13 17.5 11.4 19a3.9 3.9 0 0 1-5.5-5.5L7.5 12"/>',
  riesgo:'<path d="M12 4 21 19.5H3Z"/><path d="M12 10v4M12 17h.01"/>',
  decision:'<path d="M5 12.5 9.5 17 19 7.5"/>',
  actividad:'<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3.5 2"/>',
  temas:'<circle cx="8" cy="9" r="4"/><circle cx="16.5" cy="9.5" r="3"/><circle cx="12.5" cy="16.5" r="3.5"/>',
  sintesis:'<path d="M12 3.5 13.8 9 19.5 10.5 13.8 12.3 12 18 10.2 12.3 4.5 10.5 10.2 9Z"/><path d="M19 16.5l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8Z"/>',
  categorias:'<rect x="4" y="5" width="12" height="3" rx="1"/><rect x="4" y="10.5" width="16" height="3" rx="1"/><rect x="4" y="16" width="8" height="3" rx="1"/>',
  grip:'<circle cx="9" cy="6" r="1.2"/><circle cx="15" cy="6" r="1.2"/><circle cx="9" cy="12" r="1.2"/><circle cx="15" cy="12" r="1.2"/><circle cx="9" cy="18" r="1.2"/><circle cx="15" cy="18" r="1.2"/>',
  left:'<path d="m14.5 6-6 6 6 6"/>', right:'<path d="m9.5 6 6 6-6 6"/>',
  wider:'<path d="M3.5 12h17M7 8.5 3.5 12 7 15.5M17 8.5l3.5 3.5-3.5 3.5"/>',
  close:'<path d="m6 6 12 12M18 6 6 18"/>', plus:'<path d="M12 5v14M5 12h14"/>',
  edit:'<path d="M4 20h4L19 9l-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/>',
  check:'<path d="M5 12.5 9.5 17 19 7.5"/>', shield:'<path d="M12 3.5 19 6v5.5c0 4.3-2.9 7.6-7 9-4.1-1.4-7-4.7-7-9V6Z"/><path d="m9 12 2 2 4-4"/>',
  clock:'<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>', refresh:'<path d="M20 12a8 8 0 1 1-2.4-5.7M20 4v4h-4"/>',
  save:'<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>', reset:'<path d="M4 12a8 8 0 1 0 2.4-5.7M4 4v4h4"/>',
  spark:'<path d="M12 3.5 13.8 9 19.5 10.5 13.8 12.3 12 18 10.2 12.3 4.5 10.5 10.2 9Z"/>',
  eye:'<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.8"/>',
  link:'<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'
};

interface IconProps { name: string; className?: string }

export function Icon({ name, className }: IconProps) {
  return (
    <svg
      className={className}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      dangerouslySetInnerHTML={{ __html: ICONS[name] ?? ICONS.spark }}
    />
  );
}
