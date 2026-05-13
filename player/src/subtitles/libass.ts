/**
 * ASS/SSA subtitle rendering via @jellyfin/libass-wasm. Mirrors how
 * jellyfin-web/src/plugins/htmlVideoPlayer integrates SubtitlesOctopus, but
 * decoupled from the apiClient — fonts and the SSA source come from the
 * host-supplied TrackProvider (or direct URLs).
 *
 * Loaded dynamically so the libass WASM blob is fetched only when needed.
 */
export interface LibassOptions {
  video: HTMLVideoElement;
  subUrl: string;
  fonts?: string[];           // URLs of additional fonts (e.g. embedded MKV attachments)
  fallbackFont?: string;      // URL of a fallback font
  workerUrl?: string;         // override location of subtitles-octopus-worker.js
  legacyWorkerUrl?: string;   // fallback for older browsers
  prescaleHeight?: number;    // upscale subtitle canvas for sharper rendering
}

export interface LibassRenderer {
  setTrackByUrl(url: string): void;
  freeTrack(): void;
  resize(): void;
  destroy(): void;
}

export async function createLibassRenderer(opts: LibassOptions): Promise<LibassRenderer | null> {
  let SubtitlesOctopus: any;
  try {
    // Runtime indirection — bundlers must not try to statically resolve this.
    const dynamicImport = new Function('m', 'return import(m)') as (m: string) => Promise<any>;
    const mod: any = await dynamicImport('@jellyfin/libass-wasm');
    SubtitlesOctopus = mod.default ?? mod;
  } catch (err) {
    console.warn('[jellyfin-rails/player] @jellyfin/libass-wasm not installed; ASS subtitles disabled.', err);
    return null;
  }

  // Pick worker URLs from the package itself unless the host overrode them.
  const workerUrl = opts.workerUrl
    ?? new URL('subtitles-octopus-worker.js',
               (window as any).JELLYFIN_LIBASS_WASM_BASE
               ?? './node_modules/@jellyfin/libass-wasm/dist/js/').toString();
  const legacyWorkerUrl = opts.legacyWorkerUrl
    ?? new URL('subtitles-octopus-worker-legacy.js',
               (window as any).JELLYFIN_LIBASS_WASM_BASE
               ?? './node_modules/@jellyfin/libass-wasm/dist/js/').toString();

  const octopus = new SubtitlesOctopus({
    video: opts.video,
    subUrl: opts.subUrl,
    fonts: opts.fonts ?? [],
    fallbackFont: opts.fallbackFont,
    workerUrl,
    legacyWorkerUrl,
    targetFps: 24,
    prescaleHeightLimit: opts.prescaleHeight ?? 1080,
    onError: (e: any) => console.error('[jellyfin-rails/player] libass error', e),
    onReady: () => { /* ready */ }
  });

  // libass renders into its own canvas overlaid on the video; resize on the
  // video element triggers a recompute. We hook into ResizeObserver so it
  // survives fullscreen / orientation / window resize.
  const ro = typeof ResizeObserver !== 'undefined'
    ? new ResizeObserver(() => octopus.resize?.())
    : null;
  ro?.observe(opts.video);

  return {
    setTrackByUrl: (url) => octopus.setTrackByUrl(url),
    freeTrack: () => octopus.freeTrack(),
    resize: () => octopus.resize?.(),
    destroy: () => { ro?.disconnect(); octopus.dispose?.(); }
  };
}
