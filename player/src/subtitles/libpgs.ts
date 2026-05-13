/**
 * PGS / HDMV bitmap subtitle rendering via the `libpgs` package.
 * Same dynamic-import pattern as libass.
 *
 * If the host needs PGS but doesn't want client-side rendering, the alternative
 * is server-side burn-in (subtitle_mode: "burn") which lands in phase 5.
 */
export interface LibpgsOptions {
  video: HTMLVideoElement;
  subUrl: string;
}

export interface LibpgsRenderer {
  setTrack(url: string): void;
  destroy(): void;
}

export async function createLibpgsRenderer(opts: LibpgsOptions): Promise<LibpgsRenderer | null> {
  let LibpgsCtor: any;
  try {
    const dynamicImport = new Function('m', 'return import(m)') as (m: string) => Promise<any>;
    const mod: any = await dynamicImport('libpgs');
    LibpgsCtor = mod.PgsRenderer ?? mod.default ?? mod;
  } catch (err) {
    console.warn('[jellyfin-rails/player] libpgs not installed; PGS subtitles disabled.', err);
    return null;
  }

  const renderer = new LibpgsCtor({
    video: opts.video,
    subUrl: opts.subUrl
  });

  return {
    setTrack: (url) => renderer.loadFromUrl(url),
    destroy: () => renderer.dispose?.()
  };
}
