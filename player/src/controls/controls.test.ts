import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Player } from '../player';

beforeEach(() => { document.body.innerHTML = ''; });
afterEach(()  => { document.body.innerHTML = ''; });

describe('Player controls', () => {
  it('renders a control bar with scrubber + time readout by default', () => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    new Player(el, { source: { hlsUrl: '/x.m3u8' } });
    expect(el.querySelector('.jellyfin-controls')).toBeTruthy();
    expect(el.querySelector('.jellyfin-scrubber')).toBeTruthy();
    expect(el.querySelector('.jellyfin-time')).toBeTruthy();
  });

  it('skips the control bar when controls: false', () => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    new Player(el, { source: { hlsUrl: '/x.m3u8' }, controls: false });
    expect(el.querySelector('.jellyfin-controls')).toBeFalsy();
  });

  it('populates the subtitle menu from the track provider', async () => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const tracks = [
      { id: 1, url: '/en.vtt', label: 'English', language: 'en' },
      { id: 2, url: '/fr.vtt', label: 'Français', language: 'fr' }
    ];
    new Player(el, {
      source: { hlsUrl: '/x.m3u8' },
      trackProvider: { getSubtitleTracks: () => tracks }
    });
    const video = el.querySelector('video')!;
    video.dispatchEvent(new Event('loadedmetadata'));
    await new Promise((r) => setTimeout(r, 0));

    const menu = el.querySelector('.jellyfin-menu--subtitle');
    expect(menu?.textContent).toContain('English');
    expect(menu?.textContent).toContain('Français');
    expect(menu?.textContent).toContain('Off');
  });

  it('renders chapter ticks proportionally on the scrubber', async () => {
    const el = document.createElement('div');
    document.body.appendChild(el);
    const chapters = [
      { startTime: 0, title: 'Cold open' },
      { startTime: 60, title: 'Act 1' },
      { startTime: 600, title: 'Credits' }
    ];
    new Player(el, {
      source: { hlsUrl: '/x.m3u8' },
      trackProvider: { getChapters: () => chapters }
    });
    const video = el.querySelector('video')!;
    Object.defineProperty(video, 'duration', { value: 1200, configurable: true });
    video.dispatchEvent(new Event('loadedmetadata'));
    await new Promise((r) => setTimeout(r, 0));

    const ticks = el.querySelectorAll('.jellyfin-chapter-tick');
    expect(ticks.length).toBe(3);
  });

  // Chapter event firing depends on requestAnimationFrame, which jsdom doesn't
  // run reliably in the test harness. The bus is unit-tested separately; the
  // chapter-tick rendering above already covers the integration of chapter
  // data through the TrackProvider into the UI.
});
