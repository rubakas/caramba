/**
 * Subtitle appearance customization. Mirrors jellyfin-web's
 * subtitleappearancehelper — controls font family/size/color/edge style for
 * VTT cues and via libass-wasm overrides for ASS/SSA.
 *
 * Persisted in localStorage so settings survive across sessions.
 */
export interface SubtitleAppearance {
  fontFamily?: string;     // CSS font-family value
  fontSize?: number;       // percentage of viewport height; default 100 (=22.5px @1080p)
  textColor?: string;      // CSS color
  textOpacity?: number;    // 0..1
  backgroundColor?: string;
  backgroundOpacity?: number;
  edgeStyle?: 'none' | 'dropshadow' | 'raised' | 'depressed' | 'uniform';
  bottomOffsetPct?: number; // % from bottom of video
}

const STORAGE_KEY = 'jellyfin-rails:subtitle-appearance';

const DEFAULT: Required<SubtitleAppearance> = {
  fontFamily: 'system-ui, -apple-system, "Helvetica Neue", sans-serif',
  fontSize: 100,
  textColor: '#ffffff',
  textOpacity: 1,
  backgroundColor: '#000000',
  backgroundOpacity: 0,      // no background by default; matches Netflix/Plex
  edgeStyle: 'dropshadow',
  bottomOffsetPct: 5
};

export function loadAppearance(): Required<SubtitleAppearance> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT };
    return { ...DEFAULT, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULT };
  }
}

export function saveAppearance(patch: Partial<SubtitleAppearance>): Required<SubtitleAppearance> {
  const merged = { ...loadAppearance(), ...patch };
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(merged)); } catch { /* */ }
  return merged;
}

/**
 * Builds a CSS string for native ::cue styling. Inject into a <style> tag
 * that's specific to the player root so it doesn't leak.
 */
export function vttCueCss(rootSelector: string, a: Required<SubtitleAppearance> = loadAppearance()): string {
  const sizePx = (a.fontSize / 100) * 22.5;
  const bg = hexWithOpacity(a.backgroundColor, a.backgroundOpacity);
  const fg = hexWithOpacity(a.textColor, a.textOpacity);
  const shadow = edgeShadow(a.edgeStyle);
  return `${rootSelector} video::cue {
    font-family: ${a.fontFamily};
    font-size: ${sizePx}px;
    color: ${fg};
    background-color: ${bg};
    text-shadow: ${shadow};
  }`;
}

function hexWithOpacity(hex: string, opacity: number): string {
  const o = Math.round(Math.max(0, Math.min(1, opacity)) * 255).toString(16).padStart(2, '0');
  if (/^#[0-9a-f]{6}$/i.test(hex)) return `${hex}${o}`;
  return hex;
}

function edgeShadow(style: SubtitleAppearance['edgeStyle']): string {
  switch (style) {
    case 'dropshadow': return '2px 2px 3px rgba(0,0,0,0.8)';
    case 'raised':     return '1px 1px 0 #444, 2px 2px 0 #222';
    case 'depressed':  return '-1px -1px 0 #444, -2px -2px 0 #222';
    case 'uniform':    return '0 0 4px #000, 0 0 4px #000, 0 0 4px #000';
    case 'none':       return 'none';
    default:           return 'none';
  }
}
