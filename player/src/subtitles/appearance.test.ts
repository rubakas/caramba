import { describe, it, expect, beforeEach } from 'vitest';
import { loadAppearance, saveAppearance, vttCueCss } from './appearance';

describe('subtitle appearance', () => {
  beforeEach(() => localStorage.removeItem('jellyfin-rails:subtitle-appearance'));

  it('returns sensible defaults when nothing is stored', () => {
    const a = loadAppearance();
    expect(a.fontSize).toBe(100);
    expect(a.textColor).toBe('#ffffff');
    expect(a.edgeStyle).toBe('dropshadow');
  });

  it('persists partial updates and merges over defaults', () => {
    saveAppearance({ fontSize: 150, textColor: '#ffff00' });
    const a = loadAppearance();
    expect(a.fontSize).toBe(150);
    expect(a.textColor).toBe('#ffff00');
    expect(a.edgeStyle).toBe('dropshadow'); // default preserved
  });

  it('emits a ::cue CSS block for the player root', () => {
    const css = vttCueCss('.jelly');
    expect(css).toMatch(/\.jelly video::cue/);
    expect(css).toMatch(/font-family:/);
    expect(css).toMatch(/text-shadow:/);
  });

  it('applies opacity to hex colors', () => {
    saveAppearance({ textColor: '#ff0000', textOpacity: 0.5 });
    const css = vttCueCss('.jelly');
    expect(css).toMatch(/#ff000080/); // 0.5 → 0x80
  });

  it('emits "none" text-shadow for edgeStyle: none', () => {
    saveAppearance({ edgeStyle: 'none' });
    const css = vttCueCss('.jelly');
    expect(css).toMatch(/text-shadow: none/);
  });
});
