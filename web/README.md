# AVIA Vigilante · web

Panel del analista del Vigilante en React. Es la conversión del prototipo `poc/vigilante.html`: mismas vistas, mismo diseño y mismos datos de ejemplo, ahora en componentes.

## Arrancar

```bash
cd web
npm install
npm run dev        # http://localhost:5173
npm run build      # comprueba tipos y genera dist/
```

Requiere Node 20 o superior.

## Datos reales del VPS

Al arrancar, la web pide `/data/vigilante.json`, el archivo que publica Hermes en el VPS (https://vigilante-bolivia.duckdns.org). Lo vuelve a pedir cada 5 minutos.

- En `npm run dev` y `npm run preview`, Vite reenvía `/data` al VPS (`vite.config.ts`), porque el VPS no permite que otras webs lean sus datos directamente desde el navegador. Para usar otro servidor: `VIGILANTE_VPS=https://otro npm run dev`.
- Si el VPS no responde, la web muestra los datos de ejemplo y lo avisa. La simulación en vivo solo funciona con los datos de ejemplo, nunca con los reales.
- La conversión del formato de `vigilante.json` al de la web está en `src/services/datos.ts`.
- Las decisiones (mover una señal, reconocer un problema) todavía no se guardan en el VPS: solo cambian el navegador y se pierden al recargar.

## Estructura

```text
src/
  main.tsx, App.tsx      entrada, atajos de teclado, preferencias y simulación
  store.ts               estado global (zustand) y todas las acciones
  types.ts               tipos del dominio (fuentes, señales, eventos…)
  data/demo.ts           datos de ejemplo inventados → se sustituyen por Supabase
  views/                 una vista por pantalla: Panorama, Fuentes, Señales, Oportunidades, Análisis, Bitácora
  panels/panels.tsx      los 12 paneles del tablero Panorama
  components/            barra lateral y superior, panel de detalle, búsqueda, chat, piezas comunes
  services/datos.ts      lectura de vigilante.json del VPS y conversión al formato de la web
  services/avia.ts       cliente del backend de AVIA + análisis local sin IA
  services/chat.ts       lógica del chat «Pregunta a AVIA»
  styles/app.css         estilos del prototipo, sin cambios
```

## Qué cambia respecto al prototipo HTML

- El HTML se generaba con plantillas de texto; ahora cada parte es un componente y el estado vive en `store.ts`.
- El prototipo llamaba a Claude con `window.claude`, que solo existe dentro de claude.ai. Aquí la IA va por un backend propio (`VITE_AVIA_API_URL`, contrato en `docs/api-avia.md`). Sin backend, el chat y el análisis usan reglas locales, igual que el modo local del prototipo.
- El distintivo de los eventos de la bitácora dice AVIA en vez de HERMES: AVIA es la marca, Hermes es el motor interno.

## Siguientes pasos

1. Guardar las decisiones en el servidor (Supabase, esquema `vigilante`, `db/generico/`) en lugar de solo en el navegador.
2. Login con la cuenta de AVIA (OIDC) y roles reales (visor, analista, administrador) en lugar del selector «Entrar como».
3. Backend de AVIA con el contrato de `docs/api-avia.md`.
4. Proteger `vigilante.json`: ahora cualquiera con la URL puede leerlo.
