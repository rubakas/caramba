import { SubtitleTrack } from '../extensions/track-provider';
import { createLibassRenderer, LibassRenderer } from './libass';
import { createLibpgsRenderer, LibpgsRenderer } from './libpgs';

export type SubtitleHandle =
  | { kind: 'native'; trackEl: HTMLTrackElement }
  | { kind: 'libass'; renderer: LibassRenderer }
  | { kind: 'libpgs'; renderer: LibpgsRenderer };

/**
 * Routes a track to the right renderer based on codec. Mirrors the
 * dispatcher in jellyfin-web/src/plugins/htmlVideoPlayer/plugin.js — we use
 * native <track> for vtt/srt, libass for ass/ssa, libpgs for pgs.
 */
export async function activateSubtitleTrack(
  video: HTMLVideoElement,
  track: SubtitleTrack
): Promise<SubtitleHandle | null> {
  const codec = (track.codec ?? inferCodec(track.url)).toLowerCase();

  if (codec === 'vtt' || codec === 'srt') {
    const el = document.createElement('track');
    el.kind = 'subtitles';
    el.src = track.url;
    el.label = track.label ?? '';
    el.srclang = track.language ?? '';
    el.default = !!track.default;
    video.appendChild(el);
    // Force `mode = 'showing'` once the track is parsed, and push cues
    // higher up the video so the host player's bottom controls don't
    // overlap them. Mirrors upstream jellyfin-web `plugin.js:1500-1512`:
    //   - explicit `mode = 'showing'` because the `default` attribute is
    //     unreliable across browsers
    //   - explicit `cue.line` because native WebVTT defaults to `auto`
    //     (browser-picked, near-bottom). The host has its own UI chrome
    //     down there, so subs need to sit above it.
    // `cue.line` is writable per the WHATWG spec; the value is a percentage
    // (0..100) from the top when `snapToLines = false` is set, otherwise a
    // line index. We use the percentage form (~84% from top = ~16% from
    // bottom) so subtitle position is resolution-independent.
    const positionCues = () => {
      const tt = el.track;
      if (!tt || !tt.cues) return;
      for (let i = 0; i < tt.cues.length; i++) {
        const cue = tt.cues[i] as VTTCue;
        if (cue.line === 'auto') {
          cue.snapToLines = false;
          cue.line = 84;
        }
      }
    };
    const showWhenReady = () => {
      try {
        positionCues();
        if (el.track) el.track.mode = 'showing';
      } catch { /* */ }
    };
    if (el.track && el.readyState >= 2) showWhenReady();
    el.addEventListener('load', showWhenReady, { once: true });
    return { kind: 'native', trackEl: el };
  }

  if (codec === 'ass' || codec === 'ssa') {
    const renderer = await createLibassRenderer({ video, subUrl: track.url });
    return renderer ? { kind: 'libass', renderer } : null;
  }

  if (codec === 'pgs') {
    const renderer = await createLibpgsRenderer({ video, subUrl: track.url });
    return renderer ? { kind: 'libpgs', renderer } : null;
  }

  console.warn(`[jellyfin-rails/player] unsupported subtitle codec: ${codec}`);
  return null;
}

export function deactivateSubtitleTrack(handle: SubtitleHandle | null): void {
  if (!handle) return;
  if (handle.kind === 'native') handle.trackEl.remove();
  if (handle.kind === 'libass') handle.renderer.destroy();
  if (handle.kind === 'libpgs') handle.renderer.destroy();
}

function inferCodec(url: string): string {
  const m = url.toLowerCase().match(/\.(vtt|srt|ass|ssa|pgs|sup)(\?|$)/);
  return m?.[1] ?? 'vtt';
}
