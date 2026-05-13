import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  hlsConfigForBrowser, normalizeCodecString, installStallWatchdog,
  installVisibilityResume, createBlobUrlTracker, bindBrowserSpecificHlsRecovery
} from './mse-workarounds';
import { detectBrowser } from './browser';

describe('hlsConfigForBrowser', () => {
  it('uses a tighter buffer on Firefox', () => {
    const cfg = hlsConfigForBrowser(detectBrowser('Mozilla/5.0 Firefox/123'));
    expect(cfg.maxBufferLength).toBe(20);
    expect(cfg.maxBufferSize).toBe(30 * 1000 * 1000);
    expect(cfg.startFragPrefetch).toBe(false);
  });

  it('uses a moderate buffer on Edge', () => {
    const cfg = hlsConfigForBrowser(detectBrowser('AppleWebKit/537 Chrome/120 Safari/537 Edg/120'));
    expect(cfg.maxBufferLength).toBe(25);
  });

  it('uses the tightest buffer on Safari when routed through hls.js', () => {
    const cfg = hlsConfigForBrowser(detectBrowser('Macintosh AppleWebKit/605 Version/17 Safari/605'));
    expect(cfg.maxBufferLength).toBe(15);
  });

  it('uses defaults on Chrome', () => {
    const cfg = hlsConfigForBrowser(detectBrowser('AppleWebKit/537 Chrome/120 Safari/537'));
    expect(cfg.maxBufferLength).toBe(30);
  });

  it('always enables the worker and back-buffer', () => {
    const cfg = hlsConfigForBrowser(detectBrowser('Firefox/123'));
    expect(cfg.enableWorker).toBe(true);
    expect(cfg.backBufferLength).toBe(90);
  });
});

describe('normalizeCodecString', () => {
  it('lowercases codec params (Firefox case-sensitivity workaround)', () => {
    const out = normalizeCodecString('video/mp4; codecs="avc1.42E01E,mp4a.40.2"');
    expect(out).toBe('video/mp4; codecs="avc1.42e01e,mp4a.40.2"');
  });

  it('leaves the MIME type alone', () => {
    const out = normalizeCodecString('VIDEO/MP4; codecs="AVC1.4D401E"');
    expect(out).toMatch(/^VIDEO\/MP4;/);
    expect(out).toMatch(/codecs="avc1\.4d401e"/);
  });

  it('handles whitespace around codec entries', () => {
    const out = normalizeCodecString('video/mp4; codecs="  AVC1.42E01E  ,  MP4A.40.2  "');
    expect(out).toBe('video/mp4; codecs="avc1.42e01e,mp4a.40.2"');
  });

  it('is a no-op when no codecs param is present', () => {
    const out = normalizeCodecString('video/mp4');
    expect(out).toBe('video/mp4');
  });
});

describe('installStallWatchdog', () => {
  beforeEach(() => { vi.useFakeTimers(); });
  afterEach(()  => { vi.useRealTimers(); });

  function fakeVideo({ currentTime = 0, paused = false, ended = false, readyState = 4 } = {}) {
    return { currentTime, paused, ended, readyState } as HTMLVideoElement;
  }

  it('fires onStall when currentTime has not advanced for staleAfterMs', () => {
    const onStall = vi.fn();
    const video = fakeVideo({ currentTime: 10 });
    installStallWatchdog(video, onStall, { staleAfterMs: 2000, pollMs: 500 });

    // Tick 1 — no change, not yet stale.
    vi.advanceTimersByTime(500); expect(onStall).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1000); expect(onStall).not.toHaveBeenCalled();
    // Tick 5 — stale.
    vi.advanceTimersByTime(1000);
    expect(onStall).toHaveBeenCalledTimes(1);
  });

  it('resets the stall timer when currentTime advances', () => {
    const onStall = vi.fn();
    const video = fakeVideo({ currentTime: 10 });
    installStallWatchdog(video, onStall, { staleAfterMs: 2000, pollMs: 500 });
    vi.advanceTimersByTime(1500);
    video.currentTime = 11;
    vi.advanceTimersByTime(1500);
    expect(onStall).not.toHaveBeenCalled();
  });

  it('does not fire when video is paused', () => {
    const onStall = vi.fn();
    const video = fakeVideo({ paused: true });
    installStallWatchdog(video, onStall, { staleAfterMs: 1000, pollMs: 500 });
    vi.advanceTimersByTime(3000);
    expect(onStall).not.toHaveBeenCalled();
  });

  it('does not fire when video readyState < 2 (genuine buffering)', () => {
    const onStall = vi.fn();
    const video = fakeVideo({ readyState: 1 });
    installStallWatchdog(video, onStall, { staleAfterMs: 1000, pollMs: 500 });
    vi.advanceTimersByTime(3000);
    expect(onStall).not.toHaveBeenCalled();
  });

  it('stop() halts the watchdog', () => {
    const onStall = vi.fn();
    const video = fakeVideo();
    const h = installStallWatchdog(video, onStall, { staleAfterMs: 1000, pollMs: 500 });
    h.stop();
    vi.advanceTimersByTime(5000);
    expect(onStall).not.toHaveBeenCalled();
  });
});

describe('installVisibilityResume', () => {
  it('calls play() when visibility returns and was playing before hide', async () => {
    vi.useFakeTimers();
    const video = document.createElement('video');
    const playSpy = vi.spyOn(video, 'play').mockResolvedValue();
    installVisibilityResume(video);

    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    Object.defineProperty(video, 'paused', { value: false, configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));

    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));

    vi.advanceTimersByTime(200);
    expect(playSpy).toHaveBeenCalled();
    vi.useRealTimers();
  });

  it('does not call play() when paused at hide time', async () => {
    vi.useFakeTimers();
    const video = document.createElement('video');
    const playSpy = vi.spyOn(video, 'play').mockResolvedValue();
    installVisibilityResume(video);

    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    Object.defineProperty(video, 'paused', { value: true, configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
    Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));

    vi.advanceTimersByTime(200);
    expect(playSpy).not.toHaveBeenCalled();
    vi.useRealTimers();
  });
});

describe('createBlobUrlTracker', () => {
  it('tracks blob: URLs and revokes them on cleanup', () => {
    const revoked: string[] = [];
    const origRevoke = URL.revokeObjectURL;
    (URL as any).revokeObjectURL = (u: string) => revoked.push(u);

    const t = createBlobUrlTracker();
    t.track('blob:https://example.com/1');
    t.track('https://example.com/not-blob');
    t.track('blob:https://example.com/2');
    t.cleanup();

    expect(revoked.sort()).toEqual(['blob:https://example.com/1', 'blob:https://example.com/2']);
    URL.revokeObjectURL = origRevoke;
  });
});

describe('bindBrowserSpecificHlsRecovery on Firefox', () => {
  it('escalates to stop + swapAudioCodec + recoverMediaError + startLoad for buffer errors', () => {
    const calls: string[] = [];
    const fakeHls = {
      constructor: {
        Events: { ERROR: 'hlsError' },
        ErrorTypes: { MEDIA_ERROR: 'mediaError', NETWORK_ERROR: 'networkError' }
      },
      stopLoad:           () => calls.push('stopLoad'),
      swapAudioCodec:     () => calls.push('swapAudioCodec'),
      recoverMediaError:  () => calls.push('recoverMediaError'),
      startLoad:          () => calls.push('startLoad'),
      destroy:            () => calls.push('destroy'),
      on: (_evt: string, fn: any) => { (fakeHls as any).handler = fn; }
    };

    bindBrowserSpecificHlsRecovery(fakeHls, detectBrowser('Firefox/123'), () => calls.push('giveup'));
    (fakeHls as any).handler({}, { fatal: true, type: 'mediaError', details: 'bufferAppendError' });

    expect(calls).toEqual(['stopLoad', 'swapAudioCodec', 'recoverMediaError', 'startLoad']);
  });

  it('gives up after 3 buffer errors', () => {
    const calls: string[] = [];
    const fakeHls = {
      constructor: {
        Events: { ERROR: 'hlsError' },
        ErrorTypes: { MEDIA_ERROR: 'mediaError', NETWORK_ERROR: 'networkError' }
      },
      stopLoad: vi.fn(), swapAudioCodec: vi.fn(), recoverMediaError: vi.fn(),
      startLoad: vi.fn(), destroy: () => calls.push('destroy'),
      on: (_evt: string, fn: any) => { (fakeHls as any).handler = fn; }
    };
    bindBrowserSpecificHlsRecovery(fakeHls, detectBrowser('Firefox/123'), () => calls.push('giveup'));
    const fire = () => (fakeHls as any).handler({}, { fatal: true, type: 'mediaError', details: 'bufferAppendError' });
    fire(); fire(); fire();
    expect(calls).toContain('giveup');
    expect(calls).toContain('destroy');
  });

  it('is a no-op on Chrome', () => {
    const calls: string[] = [];
    const fakeHls = {
      constructor: {
        Events: { ERROR: 'hlsError' },
        ErrorTypes: { MEDIA_ERROR: 'mediaError', NETWORK_ERROR: 'networkError' }
      },
      stopLoad: vi.fn(), swapAudioCodec: vi.fn(), recoverMediaError: vi.fn(),
      startLoad: vi.fn(), destroy: vi.fn(),
      on: (_evt: string, fn: any) => { (fakeHls as any).handler = fn; }
    };
    bindBrowserSpecificHlsRecovery(fakeHls, detectBrowser('Chrome/120'), () => calls.push('giveup'));
    (fakeHls as any).handler({}, { fatal: true, type: 'mediaError', details: 'bufferAppendError' });
    expect(calls).toEqual([]);
  });
});
