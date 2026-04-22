import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import path from 'path'

const SENTRY_RELEASE = process.env.SENTRY_RELEASE || 'dev'

export default defineConfig({
  plugins: [
    react(),
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT_WEB || 'caramba-web',
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: SENTRY_RELEASE },
      sourcemaps: { filesToDeleteAfterUpload: ['dist/**/*.js.map'] },
      disable: !process.env.SENTRY_AUTH_TOKEN,
      telemetry: false,
    }),
  ],
  base: '/',
  define: {
    __SENTRY_RELEASE__: JSON.stringify(SENTRY_RELEASE),
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: 'hidden',
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: false,
        headers: { 'X-Forwarded-Proto': 'http' },
      },
      '/rails': { target: 'http://localhost:3001', changeOrigin: false },
      '/up': { target: 'http://localhost:3001', changeOrigin: true },
    },
  },
  resolve: {
    alias: { '@caramba/ui': path.resolve(__dirname, '../ui') },
  },
})
