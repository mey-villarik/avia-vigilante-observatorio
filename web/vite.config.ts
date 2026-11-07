import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

// El VPS no permite que otras webs lean sus datos desde el navegador (no envía cabeceras CORS).
// En desarrollo (npm run dev) y en vista previa (npm run preview), Vite reenvía /data al VPS,
// así que la web pide /data/vigilante.json como si estuviera en el mismo servidor.
// Para usar otro servidor: VIGILANTE_VPS=https://otro-servidor npm run dev
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '');
  const vps = env.VIGILANTE_VPS || 'https://vigilante-bolivia.duckdns.org';
  const proxy = { '/data': { target: vps, changeOrigin: true, secure: true } };
  return {
    plugins: [react()],
    server: { proxy },
    preview: { proxy },
  };
});
