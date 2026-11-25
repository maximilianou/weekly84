import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// WEB_PORT / API_PORT / API_HOST are injected by the kit bootstrap (see
// kit/devstack/files/bootstrap/10-devstack.sh -> web/.env, sourced by vite).
// API_HOST selects who fronts the API: loopback in the sandbox (default),
// the compose service name (`api`) in the standalone docker compose stack.
const webPort = Number(process.env.WEB_PORT ?? 5173);
const apiPort = Number(process.env.API_PORT ?? 4000);
const apiHost = process.env.API_HOST ?? '127.0.0.1';

export default defineConfig({
  plugins: [react()],
  server: {
    // host: true -> accept connections forwarded by the sbx runtime from the
    // host browser. strictPort -> fail loudly instead of drifting to :5174.
    host: true,
    port: webPort,
    strictPort: true,
    proxy: {
      // web -> api; the browser only ever talks to Vite.
      '/api': {
        target: `http://${apiHost}:${apiPort}`,
        changeOrigin: true,
      },
    },
  },
});
