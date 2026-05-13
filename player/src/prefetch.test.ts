import { describe, it, expect, vi } from 'vitest';
import { resolveUrl, shouldUsePrefetchHack } from './media-helper';

describe('iOS/Safari HLS prefetch hack', () => {
  describe('resolveUrl', () => {
    it('resolves to the responseURL when XHR succeeds', async () => {
      class FakeXHR {
        responseURL = 'https://cdn.example.com/final/master.m3u8';
        onload: (() => void) | null = null;
        onerror: (() => void) | null = null;
        onabort: (() => void) | null = null;
        open() {}
        send() { queueMicrotask(() => this.onload?.()); }
      }
      const original = globalThis.XMLHttpRequest;
      (globalThis as any).XMLHttpRequest = FakeXHR;
      const out = await resolveUrl('/x.m3u8');
      expect(out).toBe('https://cdn.example.com/final/master.m3u8');
      (globalThis as any).XMLHttpRequest = original;
    });

    it('falls back to input URL on XHR error', async () => {
      class FailingXHR {
        responseURL = '';
        onerror: (() => void) | null = null;
        onload:  (() => void) | null = null;
        onabort: (() => void) | null = null;
        open() {}
        send() { queueMicrotask(() => this.onerror?.()); }
      }
      const original = globalThis.XMLHttpRequest;
      (globalThis as any).XMLHttpRequest = FailingXHR;
      const out = await resolveUrl('/orig.m3u8');
      expect(out).toBe('/orig.m3u8');
      (globalThis as any).XMLHttpRequest = original;
    });

    it('times out and falls back to input URL when XHR hangs', async () => {
      vi.useFakeTimers();
      class HangingXHR {
        responseURL = '';
        onload: any = null; onerror: any = null; onabort: any = null;
        open() {}
        send() { /* never fires */ }
      }
      const original = globalThis.XMLHttpRequest;
      (globalThis as any).XMLHttpRequest = HangingXHR;
      const promise = resolveUrl('/hang.m3u8', 100);
      vi.advanceTimersByTime(150);
      // Switch back to real timers so the promise can resolve via the timeout.
      vi.useRealTimers();
      const out = await promise;
      expect(out).toBe('/hang.m3u8');
      (globalThis as any).XMLHttpRequest = original;
    });

    it('falls back when XHR is not available', async () => {
      const original = globalThis.XMLHttpRequest;
      delete (globalThis as any).XMLHttpRequest;
      const out = await resolveUrl('/x.m3u8');
      expect(out).toBe('/x.m3u8');
      (globalThis as any).XMLHttpRequest = original;
    });
  });

  describe('shouldUsePrefetchHack', () => {
    function setUA(ua: string, touchPoints = 0) {
      Object.defineProperty(navigator, 'userAgent', { value: ua, configurable: true });
      Object.defineProperty(navigator, 'maxTouchPoints', { value: touchPoints, configurable: true });
    }

    it('returns true on iOS Safari', () => {
      setUA('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605 Safari/605.1');
      expect(shouldUsePrefetchHack()).toBe(true);
    });

    it('returns true on macOS Safari', () => {
      setUA('Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605 Version/17.0 Safari/605.1');
      expect(shouldUsePrefetchHack()).toBe(true);
    });

    it('returns true on iPadOS Safari (reports as Mac)', () => {
      setUA('Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605 Safari/605.1', 5);
      expect(shouldUsePrefetchHack()).toBe(true);
    });

    it('returns false on Chrome', () => {
      setUA('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537 Chrome/120 Safari/537');
      expect(shouldUsePrefetchHack()).toBe(false);
    });

    it('returns false on Firefox', () => {
      setUA('Mozilla/5.0 (Macintosh; Intel Mac OS X) Gecko/20100101 Firefox/120');
      expect(shouldUsePrefetchHack()).toBe(false);
    });

    it('returns false on Android Chrome', () => {
      setUA('Mozilla/5.0 (Linux; Android 14) AppleWebKit/537 Chrome/120 Safari/537');
      expect(shouldUsePrefetchHack()).toBe(false);
    });
  });
});
