/// <reference types="vite/client" />
interface ImportMetaEnv {
  /** URL del backend de AVIA (que habla con Hermes). Vacío = modo local sin IA. */
  readonly VITE_AVIA_API_URL?: string;
}
