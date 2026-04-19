import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

export default defineConfig({
  plugins: [react()],
  base: '/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: false,
        headers: {
          'X-Forwarded-Proto': 'http',
        },
      },
      // ActiveStorage proxy URLs — Rails returns absolute poster URLs that
      // include the request host. Because `changeOrigin: false` keeps the
      // browser's host (localhost:3000), the URLs Rails returns also point
      // at port 3000, so /rails/* must forward back to Rails too. Without
      // this rule Vite serves index.html for /rails/... and <img> tags
      // silently fail to render the poster.
      '/rails': {
        target: 'http://localhost:3001',
        changeOrigin: false,
      },
      '/up': {
        target: 'http://localhost:3001',
        changeOrigin: true,
      },
    },
  },
  resolve: {
    alias: {
      '@caramba/ui': path.resolve(__dirname, '../ui'),
    },
  },
})
