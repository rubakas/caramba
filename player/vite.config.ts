import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/index.ts'),
      name: 'JellyfinRailsPlayer',
      formats: ['es'],
      fileName: 'index'
    },
    rollupOptions: {
      external: ['hls.js']
    }
  }
});
