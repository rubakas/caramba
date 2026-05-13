import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Player } from './player';

beforeEach(() => { document.body.innerHTML = ''; });
afterEach(()  => { document.body.innerHTML = ''; });

describe('keyboard shortcuts', () => {
  function setup() {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const player = new Player(el, { source: { hlsUrl: '/x.m3u8' } });
    const video = el.querySelector('video')!;
    Object.defineProperty(video, 'duration', { value: 600, configurable: true });
    Object.defineProperty(video, 'currentTime', { value: 100, configurable: true, writable: true });
    Object.defineProperty(video, 'paused', { value: true, configurable: true, writable: true });
    return { el, video, player };
  }

  function key(target: HTMLElement, k: string) {
    target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
  }

  it('toggles play/pause on Space', () => {
    const { el, video, player } = setup();
    player['bindKeyboardShortcuts']?.(); // ensure bound
    const playSpy = vi.spyOn(video, 'play').mockResolvedValue();
    key(el, ' ');
    expect(playSpy).toHaveBeenCalled();
  });

  it('seeks back 5s on ArrowLeft', () => {
    const { el, video } = setup();
    key(el, 'ArrowLeft');
    expect(video.currentTime).toBe(95);
  });

  it('seeks forward 5s on ArrowRight', () => {
    const { el, video } = setup();
    key(el, 'ArrowRight');
    expect(video.currentTime).toBe(105);
  });

  it('jumps back 10s on j', () => {
    const { el, video } = setup();
    key(el, 'j');
    expect(video.currentTime).toBe(90);
  });

  it('jumps forward 10s on l', () => {
    const { el, video } = setup();
    key(el, 'l');
    expect(video.currentTime).toBe(110);
  });

  it('toggles mute on m', () => {
    const { el, video } = setup();
    expect(video.muted).toBe(false);
    key(el, 'm');
    expect(video.muted).toBe(true);
    key(el, 'm');
    expect(video.muted).toBe(false);
  });

  it('does not hijack keys when focus is on an input', () => {
    const { el, video } = setup();
    const input = document.createElement('input');
    el.appendChild(input);
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true, cancelable: true }));
    expect(video.currentTime).toBe(100); // unchanged
  });
});
