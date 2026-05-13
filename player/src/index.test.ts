import { describe, it, expect, vi } from 'vitest';
import { Player, VERSION, EventBus, SLOT_NAMES, registerJellyfinPlayer } from './index';

describe('@jellyfin-rails/player', () => {
  it('exports a version string', () => {
    expect(VERSION).toMatch(/^\d+\.\d+\.\d+/);
  });

  describe('EventBus', () => {
    it('dispatches subscribed events', () => {
      const bus = new EventBus();
      const fn = vi.fn();
      bus.on('play', fn);
      bus.emit('play', undefined);
      expect(fn).toHaveBeenCalledOnce();
    });

    it('returns an off-handle from .on()', () => {
      const bus = new EventBus();
      const fn = vi.fn();
      const off = bus.on('pause', fn);
      off();
      bus.emit('pause', undefined);
      expect(fn).not.toHaveBeenCalled();
    });

    it('isolates listener errors', () => {
      const bus = new EventBus();
      const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
      bus.on('progress', () => { throw new Error('boom'); });
      const ok = vi.fn();
      bus.on('progress', ok);
      bus.emit('progress', { currentTime: 1, duration: 10, buffered: 1 });
      expect(ok).toHaveBeenCalledOnce();
      consoleSpy.mockRestore();
    });
  });

  describe('Player shell', () => {
    it('constructs and mounts a video element', () => {
      const el = document.createElement('div');
      const player = new Player(el, { source: { hlsUrl: '/x.m3u8' } });
      expect(el.querySelector('video')).toBeTruthy();
      expect(el.classList.contains('jellyfin-player')).toBe(true);
      player.destroy();
    });

    it('attaches all named slots', () => {
      const el = document.createElement('div');
      new Player(el, { source: { hlsUrl: '/x.m3u8' } });
      SLOT_NAMES.forEach((name) => {
        expect(el.querySelector(`[data-jellyfin-slot="${name}"]`)).toBeTruthy();
      });
    });

    it('emits play/pause through the event bus when video fires native events', () => {
      const el = document.createElement('div');
      const player = new Player(el, { source: { hlsUrl: '/x.m3u8' } });
      const onPlay = vi.fn();
      const onPause = vi.fn();
      player.on('play', onPlay);
      player.on('pause', onPause);
      const video = el.querySelector('video')!;
      video.dispatchEvent(new Event('play'));
      video.dispatchEvent(new Event('pause'));
      expect(onPlay).toHaveBeenCalledOnce();
      expect(onPause).toHaveBeenCalledOnce();
      player.destroy();
    });

    it('forwards play() to the underlying video', () => {
      const el = document.createElement('div');
      const player = new Player(el, { source: { hlsUrl: '/x.m3u8' } });
      const video = el.querySelector('video')!;
      const spy = vi.spyOn(video, 'play').mockResolvedValue();
      player.play();
      expect(spy).toHaveBeenCalledOnce();
      player.destroy();
    });

    it('invokes reporter.onStart on first play, onProgress while playing, onStop on ended', () => {
      vi.useFakeTimers();
      const el = document.createElement('div');
      const reporter = { onStart: vi.fn(), onProgress: vi.fn(), onStop: vi.fn() };
      const player = new Player(el, {
        source: { hlsUrl: '/x.m3u8' },
        reporter,
        progressIntervalMs: 100
      });
      const video = el.querySelector('video')!;
      video.dispatchEvent(new Event('play'));
      expect(reporter.onStart).toHaveBeenCalledOnce();
      vi.advanceTimersByTime(250);
      expect(reporter.onProgress).toHaveBeenCalled();
      video.dispatchEvent(new Event('ended'));
      expect(reporter.onStop).toHaveBeenCalled();
      player.destroy();
      vi.useRealTimers();
    });
  });

  describe('custom element', () => {
    it('registers <jellyfin-player> on the customElements registry', () => {
      registerJellyfinPlayer();
      expect(customElements.get('jellyfin-player')).toBeTruthy();
    });
  });
});
