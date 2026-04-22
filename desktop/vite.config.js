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
      project: process.env.SENTRY_PROJECT_DESKTOP || 'caramba-desktop',
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: SENTRY_RELEASE },
      sourcemaps: { filesToDeleteAfterUpload: ['dist-react/**/*.js.map'] },
      disable: !process.env.SENTRY_AUTH_TOKEN,
      telemetry: false,
    }),
  ],
  base: './',
  define: {
    __SENTRY_RELEASE__: JSON.stringify(SENTRY_RELEASE),
  },
  build: {
    outDir: 'dist-react',
    emptyOutDir: true,
    sourcemap: 'hidden',
  },
  server: { port: 5173 },
  resolve: {
    alias: { '@caramba/ui': path.resolve(__dirname, '../ui') },
  },
})
