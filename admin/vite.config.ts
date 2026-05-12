// Last updated: May 11, 2026 - 8:17pm - GitHub Copilot (GPT-5.3-Codex)
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';

const DEV_SERVER_ORIGIN = 'http://127.0.0.1:3000';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  // Pre-bundle heavy ESM packages so Vite doesn't transform thousands
  // of individual icon/module files one at a time during the dev server
  // warm-up. This is the primary cause of the 3+ min build hang.
  optimizeDeps: {
    include: [
      'lucide-react',
      '@tanstack/react-query',
      'socket.io-client',
      'sonner',
    ],
  },
  server: {
    port: 5173,
    proxy: {
      '/api': DEV_SERVER_ORIGIN,
      '/clips': DEV_SERVER_ORIGIN,
      '/socket.io': {
        target: DEV_SERVER_ORIGIN,
        ws: true,
      },
    },
  },
  build: {
    outDir: '../server/public',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // Group lucide-react into its own chunk so Rollup processes
        // all 1,764 icon files as a single unit — not one pass each.
        manualChunks: {
          'vendor-icons': ['lucide-react'],
          'vendor-react': ['react', 'react-dom'],
          'vendor-query': ['@tanstack/react-query'],
          'vendor-socket': ['socket.io-client'],
        },
      },
    },
  },
});
