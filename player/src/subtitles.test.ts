import { describe, it, expect } from 'vitest';
import { activateSubtitleTrack, deactivateSubtitleTrack } from './subtitles';

describe('subtitles dispatcher', () => {
  it('attaches a native <track> element for vtt', async () => {
    const video = document.createElement('video');
    const handle = await activateSubtitleTrack(video, {
      id: 1,
      url: 'https://example.com/en.vtt',
      codec: 'vtt',
      language: 'en',
      label: 'English',
      default: true
    });
    expect(handle?.kind).toBe('native');
    expect(video.querySelector('track')?.src).toBe('https://example.com/en.vtt');
    deactivateSubtitleTrack(handle);
    expect(video.querySelector('track')).toBeNull();
  });

  it('falls back gracefully when libass-wasm is not installed', async () => {
    const video = document.createElement('video');
    const handle = await activateSubtitleTrack(video, {
      id: 2,
      url: 'https://example.com/sub.ass',
      codec: 'ass'
    });
    expect(handle).toBeNull();
  });

  it('infers codec from URL extension', async () => {
    const video = document.createElement('video');
    const handle = await activateSubtitleTrack(video, { id: 3, url: '/en.srt' });
    expect(handle?.kind).toBe('native');
  });
});
