/**
 * Ports jellyfin-web/src/components/htmlMediaHelper.js (394 LOC) — the
 * collection of small helpers that handle the awkward bits of HTML5 media:
 * HLS.js lifecycle, error recovery, volume persistence, autoplay-rejection
 * handling, and buffered-range serialization.
 */

const VOLUME_KEY = 'jellyfin-rails:volume';

export function getSavedVolume(): number {
  try {
    const raw = localStorage.getItem(VOLUME_KEY);
    if (!raw) return 1.0;
    const n = parseFloat(raw);
    return Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : 1.0;
  } catch {
    return 1.0;
  }
}

export function saveVolume(v: number): void {
  try {
    localStorage.setItem(VOLUME_KEY, String(Math.max(0, Math.min(1, v))));
  } catch {
    // localStorage may throw in private mode / over quota — ignore.
  }
}

export function isValidDuration(d: number | undefined): boolean {
  return d !== undefined && Number.isFinite(d) && d > 0;
}

export interface BufferedRange {
  start: number;
  end: number;
}

export function getBufferedRanges(media: HTMLMediaElement): BufferedRange[] {
  const ranges: BufferedRange[] = [];
  const tr = media.buffered;
  if (!tr) return ranges;
  for (let i = 0; i < tr.length; i++) {
    ranges.push({ start: tr.start(i), end: tr.end(i) });
  }
  return ranges;
}

export function getCrossOriginValue(_src: string): 'anonymous' | 'use-credentials' {
  // Upstream picks based on whether credentials are needed for the apiClient.
  // We default to anonymous because Rails sessions don't ride along on HLS
  // segment fetches unless the host explicitly opts in.
  return 'anonymous';
}

/**
 * iOS / Safari HLS prefetch hack. Ports the technique from jellyfin-web's
 * htmlVideoPlayer/plugin.js:resolveUrl.
 *
 * Safari's native HLS engine doesn't warm DNS/TCP/TLS or follow redirects
 * until `video.play()` fires — which gives a noticeable 500ms–2s delay before
 * the first frame on iOS. We fire an XHR HEAD to the manifest URL ahead of
 * `video.src = url` so the connection is hot and any redirects are resolved.
 *
 * Returns the redirected URL (or the input URL if no redirect occurred). Falls
 * back to the input URL on any error — this is a "free perf, never block"
 * helper, not a critical-path operation.
 */
export function resolveUrl(url: string, timeoutMs = 5000): Promise<string> {
  return new Promise((resolve) => {
    if (typeof XMLHttpRequest === 'undefined') return resolve(url);

    const xhr = new XMLHttpRequest();
    let done = false;
    const finish = (result: string) => {
      if (done) return;
      done = true;
      resolve(result);
    };

    const t = setTimeout(() => finish(url), timeoutMs);

    try {
      xhr.open('HEAD', url, true);
      xhr.onload = () => { clearTimeout(t); finish(xhr.responseURL || url); };
      xhr.onerror = () => { clearTimeout(t); finish(url); };
      xhr.onabort = () => { clearTimeout(t); finish(url); };
      xhr.send(null);
    } catch {
      clearTimeout(t);
      finish(url);
    }
  });
}

/**
 * True for browsers where the native HLS prefetch hack is worth applying.
 * Conservative: iOS Safari, iPadOS Safari, macOS Safari. Other browsers don't
 * have native HLS (they go through hls.js which prefetches itself).
 */
export function shouldUsePrefetchHack(): boolean {
  if (typeof navigator === 'undefined') return false;
  const ua = navigator.userAgent;
  // iPadOS 13+ identifies as Mac on Safari — both want the hack.
  const isSafari = /^((?!chrome|android|crios|fxios|edgios).)*safari/i.test(ua);
  const isiOS = /iPad|iPhone|iPod/.test(ua) || (navigator.maxTouchPoints > 1 && /Mac/.test(ua));
  return isSafari || isiOS;
}

/** Codecs we ALWAYS use hls.js for, even when the browser claims native HLS. */
const HLS_JS_FORCED_CODECS = new Set([
  'hevc', 'h265',           // Safari supports HEVC in fmp4 only, hls.js routes it correctly
  'av1', 'av01',
  'vp9'                     // some Safari versions choke on VP9 in TS
]);

export function enableHlsJsPlayerForCodecs(codecs: string[], native: boolean): boolean {
  if (codecs.some((c) => HLS_JS_FORCED_CODECS.has(c.toLowerCase()))) return true;
  return !native;
}

/** Wraps video.play() to handle the autoplay-rejection promise correctly. */
export function playWithPromise(video: HTMLVideoElement): Promise<void> {
  try {
    const p = video.play();
    if (p && typeof p.then === 'function') {
      return p.catch((err: any) => {
        // Autoplay rejected (no user gesture). Surface a meaningful error
        // instead of an unhandled rejection — the host can recover by
        // muting and trying again, or by showing a play button.
        if (err && err.name === 'NotAllowedError') {
          console.warn('[jellyfin-rails/player] autoplay blocked; user gesture required');
        }
        throw err;
      });
    }
    return Promise.resolve();
  } catch (err) {
    return Promise.reject(err);
  }
}

/**
 * HLS.js fatal-error recovery ladder. Mirrors `handleHlsJsMediaError` in upstream.
 *
 *   network error  → hls.startLoad()
 *   media error 1× → hls.recoverMediaError()
 *   media error 2× → hls.swapAudioCodec(); hls.recoverMediaError()
 *   media error 3× → destroy + surface 'error' event
 */
export function bindHlsErrorRecovery(hls: any, onUnrecoverable: (msg: string) => void): void {
  let mediaRecoveryAttempts = 0;
  const Hls = hls.constructor; // hls.js exposes static Hls.ErrorTypes
  hls.on(Hls.Events.ERROR, (_evt: any, data: any) => {
    if (!data.fatal) return;
    switch (data.type) {
      case Hls.ErrorTypes.NETWORK_ERROR:
        // Recoverable: retry segment load.
        hls.startLoad();
        return;
      case Hls.ErrorTypes.MEDIA_ERROR:
        mediaRecoveryAttempts++;
        if (mediaRecoveryAttempts === 1) {
          hls.recoverMediaError();
        } else if (mediaRecoveryAttempts === 2) {
          hls.swapAudioCodec();
          hls.recoverMediaError();
        } else {
          onUnrecoverable('media error: too many recovery attempts');
          hls.destroy();
        }
        return;
      default:
        onUnrecoverable(`fatal hls error: ${data.type} / ${data.details}`);
        hls.destroy();
    }
  });
}

/** Restore playback position once `loadedmetadata` fires. Used after src swaps. */
export function seekOnPlaybackStart(video: HTMLVideoElement, seconds: number): () => void {
  const handler = () => {
    if (seconds > 0 && isValidDuration(video.duration) && seconds < video.duration) {
      video.currentTime = seconds;
    }
    video.removeEventListener('loadedmetadata', handler);
  };
  video.addEventListener('loadedmetadata', handler);
  return () => video.removeEventListener('loadedmetadata', handler);
}

/** Maps an HTMLMediaElement error to a human-readable string. */
export function describeMediaError(err: MediaError | null | undefined): string {
  if (!err) return 'unknown media error';
  switch (err.code) {
    case 1: return 'playback aborted';
    case 2: return 'network error during playback';
    case 3: return 'decoder error — codec or container not supported';
    case 4: return 'source not supported by this browser';
    default: return err.message || 'unknown media error';
  }
}
