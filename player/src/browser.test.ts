import { describe, it, expect } from 'vitest';
import { detectBrowser } from './browser';

describe('detectBrowser', () => {
  it('identifies Firefox', () => {
    const b = detectBrowser('Mozilla/5.0 (Macintosh) Gecko/20100101 Firefox/123.0');
    expect(b.name).toBe('firefox');
    expect(b.version).toBe(123);
    expect(b.isFirefox).toBe(true);
  });

  it('identifies Chromium-based Edge', () => {
    const b = detectBrowser('Mozilla/5.0 AppleWebKit/537 Chrome/120 Safari/537 Edg/120.0.2210.121');
    expect(b.name).toBe('chromium-edge');
    expect(b.version).toBe(120);
    expect(b.isEdge).toBe(true);
    expect(b.isChrome).toBe(false);
  });

  it('identifies legacy Edge', () => {
    const b = detectBrowser('Mozilla/5.0 AppleWebKit/537 Chrome/65 Safari/537 Edge/18.18362');
    expect(b.name).toBe('legacy-edge');
    expect(b.isEdge).toBe(true);
  });

  it('identifies Chrome (and only Chrome, when Edge is not present)', () => {
    const b = detectBrowser('Mozilla/5.0 AppleWebKit/537 Chrome/120 Safari/537');
    expect(b.name).toBe('chrome');
    expect(b.version).toBe(120);
    expect(b.isChrome).toBe(true);
    expect(b.isEdge).toBe(false);
  });

  it('identifies Safari', () => {
    const b = detectBrowser('Mozilla/5.0 (Macintosh) AppleWebKit/605 Version/17 Safari/605');
    expect(b.name).toBe('safari');
    expect(b.isSafari).toBe(true);
  });

  it('flags mobile UAs', () => {
    const b = detectBrowser('Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537 Chrome/120');
    expect(b.isMobile).toBe(true);
  });

  it('falls back to "other" on unknown UAs', () => {
    const b = detectBrowser('SomeFutureBrowser/1.0');
    expect(b.name).toBe('other');
  });
});
