// Last updated: May 13, 2026 - 2:20pm - GitHub Copilot (GPT-5.3-Codex)
import { sentryVitePlugin } from '@sentry/vite-plugin';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';
import { defineConfig, loadEnv } from 'vite';

const DEV_SERVER_ORIGIN = 'http://127.0.0.1:3000';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const isProductionBuild = mode === 'production';
  const hasSentryBuildCredentials = Boolean(env.SENTRY_AUTH_TOKEN && env.SENTRY_ORG && env.SENTRY_PROJECT);

  const plugins = [react(), tailwindcss()];

  if (isProductionBuild && hasSentryBuildCredentials) {
    plugins.push(
      sentryVitePlugin({
        authToken: env.SENTRY_AUTH_TOKEN,
        org: env.SENTRY_ORG,
        project: env.SENTRY_PROJECT,
        telemetry: false,
        release: {
          name: env.SENTRY_RELEASE || env.VITE_SENTRY_RELEASE || env.RENDER_GIT_COMMIT || env.GITHUB_SHA,
        },
        sourcemaps: {
          assets: '../server/public/assets/**',
        },
      }),
    );
  }

  return {
    plugins,
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
      // Source maps are only needed when Sentry upload is enabled for production builds.
      sourcemap: isProductionBuild && hasSentryBuildCredentials,
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
  };
});
