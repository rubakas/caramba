/**
 * Firefox / Edge MSE workarounds. Collected from observed real-world bugs
 * and jellyfin-web's upstream htmlVideoPlayer experience.
 *
 * Each helper here is a no-op on browsers that don't need it — gating on UA
 * detection inside the helpers keeps the call sites clean.
 */
import { detectBrowser, BrowserInfo } from './browser';

/**
 * Returns an HLS.js config object tuned for the current browser. Conservative
 * defaults for Chrome/Safari, smaller buffers + worker forcing on Firefox/Edge.
 *
 * The values here are derived from upstream jellyfin-web defaults plus
 * Firefox's known sloppier MSE buffer eviction:
 *
 *   - `maxBufferLength` — seconds of forward buffer; Firefox OOMs with 60+
 *   - `maxBufferSize` — bytes cap; Firefox needs an explicit cap because its
 *     default eviction policy can let MSE grow to ~150MB before evicting
 *   - `backBufferLength` — seconds of behind-playhead buffer; useful for
 *     seek-back without re-download. Default 0 (off) on Chrome wastes memory.
 *   - `enableWorker` — moves demuxing off the main thread; bigger win on
 *     Firefox where main-thread perf is lower
 */
export function hlsConfigForBrowser(browser: BrowserInfo = detectBrowser()): Record<string, any> {
  const base: Record<string, any> = {
    enableWorker: true,
    lowLatencyMode: false,
    backBufferLength: 90,
    maxBufferLength: 30,
    maxBufferSize: 60 * 1000 * 1000,
    fragLoadingMaxRetry: 6,
    manifestLoadingMaxRetry: 6,
    levelLoadingMaxRetry: 6
  };

  if (browser.isFirefox) {
    // Firefox MSE eviction is sloppy; smaller buffer + explicit retry on
    // network errors so we don't lose playback on transient hiccups.
    return {
      ...base,
      maxBufferLength: 20,
      maxBufferSize: 30 * 1000 * 1000,
      maxMaxBufferLength: 60,
      // Firefox MSE has trouble with high-PTS segments; cap segment lookahead.
      maxFragLookUpTolerance: 0.5,
      // Use the manifest-declared start, not heuristics — Firefox's PTS
      // detection is unreliable.
      startFragPrefetch: false
    };
  }

  if (browser.isEdge) {
    // Edge (Chromium) inherits most Chrome behavior, but Edge on Xbox / older
    // Chromium versions has stricter MSE quotas. Keep buffers small to avoid
    // hitting them.
    return {
      ...base,
      maxBufferLength: 25,
      maxBufferSize: 40 * 1000 * 1000
    };
  }

  if (browser.isSafari) {
    // Safari mostly uses native HLS, but when we route through hls.js (HEVC /
    // AV1 / VP9), keep buffer small because Safari's MSE quota is the
    // tightest of the majors.
    return {
      ...base,
      maxBufferLength: 15,
      maxBufferSize: 25 * 1000 * 1000
    };
  }

  return base;
}

/**
 * Normalize a codec string for `MediaSource.isTypeSupported`. Firefox is
 * case-sensitive on the codec sub-string (e.g. `avc1.42E01E` is rejected,
 * `avc1.42e01e` is accepted); Chrome accepts both. We always lowercase the
 * codec params; the MIME type stays as-is.
 */
export function normalizeCodecString(input: string): string {
  // Format: 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"'
  return input.replace(/codecs="([^"]+)"/, (_m, codecs: string) => {
    const lc = codecs
      .split(',')
      .map((c) => c.trim().toLowerCase())
      .join(',');
    return `codecs="${lc}"`;
  });
}

/**
 * Installs a "stall watchdog" — fires `onStall(stalledSeconds)` when the
 * playhead hasn't advanced for `staleAfterMs` while the video isn't paused
 * and isn't already showing the `waiting` event.
 *
 * Firefox in particular can get stuck mid-stream without firing `error` or
 * `stalled` — the watchdog gives us a chance to recover (seek by 0.1s,
 * call `recoverMediaError`, etc.) before the user gives up and reloads.
 */
export interface StallWatchdogHandle {
  stop(): void;
}

export function installStallWatchdog(
  video: HTMLVideoElement,
  onStall: () => void,
  opts: { staleAfterMs?: number; pollMs?: number } = {}
): StallWatchdogHandle {
  const staleAfter = opts.staleAfterMs ?? 8000;
  const poll = opts.pollMs ?? 1000;
  let lastTime = video.currentTime;
  let lastChangeAt = Date.now();

  const id = setInterval(() => {
    if (video.paused || video.ended) {
      lastTime = video.currentTime;
      lastChangeAt = Date.now();
      return;
    }
    if (video.readyState < 2 /* HAVE_CURRENT_DATA */) {
      // Genuinely buffering — that's `waiting`, not a stall.
      lastTime = video.currentTime;
      lastChangeAt = Date.now();
      return;
    }
    if (video.currentTime !== lastTime) {
      lastTime = video.currentTime;
      lastChangeAt = Date.now();
      return;
    }
    if (Date.now() - lastChangeAt > staleAfter) {
      // Reset before firing so we don't spam the recovery callback.
      lastChangeAt = Date.now();
      onStall();
    }
  }, poll);

  return { stop: () => clearInterval(id) };
}

/**
 * Page Visibility API hook. Firefox suspends background AudioContext and
 * sometimes pauses MSE source-buffer updates when the tab is hidden. When
 * visibility returns, we re-issue `play()` if we *were* playing — otherwise
 * Firefox can leave the playhead frozen until the user clicks something.
 */
export function installVisibilityResume(video: HTMLVideoElement): () => void {
  if (typeof document === 'undefined') return () => {};

  let wasPlayingWhenHidden = false;
  const onVisChange = () => {
    if (document.visibilityState === 'hidden') {
      wasPlayingWhenHidden = !video.paused && !video.ended;
    } else if (document.visibilityState === 'visible' && wasPlayingWhenHidden) {
      // Tiny delay lets the browser settle. play() is idempotent so safe to
      // call even if it's already playing.
      setTimeout(() => video.play().catch(() => {}), 100);
      wasPlayingWhenHidden = false;
    }
  };
  document.addEventListener('visibilitychange', onVisChange);
  return () => document.removeEventListener('visibilitychange', onVisChange);
}

/**
 * Tracks blob: URLs created during a player session and revokes them when
 * the cleanup function is called. Firefox in particular leaks MediaSource
 * blobs that aren't explicitly revoked — Chrome GCs them but Firefox doesn't.
 */
export function createBlobUrlTracker(): {
  track(url: string): string;
  cleanup(): void;
} {
  const urls = new Set<string>();
  return {
    track(url: string) {
      if (url.startsWith('blob:')) urls.add(url);
      return url;
    },
    cleanup() {
      urls.forEach((u) => {
        try { URL.revokeObjectURL(u); } catch { /* ignore */ }
      });
      urls.clear();
    }
  };
}

/**
 * Wraps an HLS.js instance with extra recovery beyond the default ladder.
 *
 * Firefox-specific: when a MEDIA_ERROR fires with a `bufferAppendError` or
 * `bufferAddCodecError`, Firefox often won't recover via `recoverMediaError`
 * alone — needs a stop + buffer-flush + start. We add that as a third-level
 * recovery beyond the standard swapAudioCodec path.
 */
export function bindBrowserSpecificHlsRecovery(
  hls: any,
  browser: BrowserInfo = detectBrowser(),
  onUnrecoverable: (msg: string) => void
): void {
  const Hls = hls.constructor;
  let bufferRecoveryAttempts = 0;
  hls.on(Hls.Events.ERROR, (_e: any, data: any) => {
    if (!data.fatal) return;
    const isBufferProblem = data.details === 'bufferAppendError' ||
                            data.details === 'bufferAddCodecError' ||
                            data.details === 'bufferAppendingError';
    if (browser.isFirefox && data.type === Hls.ErrorTypes.MEDIA_ERROR && isBufferProblem) {
      bufferRecoveryAttempts++;
      if (bufferRecoveryAttempts > 2) {
        onUnrecoverable(`firefox buffer error unrecoverable: ${data.details}`);
        hls.destroy();
        return;
      }
      // Aggressive recovery for Firefox: stop, swap codec, restart.
      try {
        hls.stopLoad();
        hls.swapAudioCodec();
        hls.recoverMediaError();
        hls.startLoad();
      } catch (e) {
        onUnrecoverable(`firefox recovery exception: ${String(e)}`);
      }
    }
  });
}
