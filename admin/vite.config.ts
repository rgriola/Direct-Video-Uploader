import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';

// Point the dev server at another local API, e.g. an isolated test server:
// DVU_API_TARGET=http://127.0.0.1:3001 npm run dev
const apiTarget = process.env.DVU_API_TARGET || 'http://localhost:3000';

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
      '/api': apiTarget,
      '/clips': apiTarget,
      '/socket.io': {
        target: apiTarget,
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
