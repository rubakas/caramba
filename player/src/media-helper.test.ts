import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  getSavedVolume, saveVolume, isValidDuration, getBufferedRanges,
  enableHlsJsPlayerForCodecs, playWithPromise, describeMediaError
} from './media-helper';

describe('media-helper', () => {
  describe('volume persistence', () => {
    beforeEach(() => localStorage.removeItem('jellyfin-rails:volume'));

    it('returns 1.0 when nothing is saved', () => {
      expect(getSavedVolume()).toBe(1.0);
    });

    it('roundtrips a saved volume', () => {
      saveVolume(0.42);
      expect(getSavedVolume()).toBeCloseTo(0.42);
    });

    it('clamps to [0, 1]', () => {
      saveVolume(2);
      expect(getSavedVolume()).toBe(1);
      saveVolume(-0.5);
      expect(getSavedVolume()).toBe(0);
    });
  });

  describe('isValidDuration', () => {
    it('rejects NaN, Infinity, 0, negatives, undefined', () => {
      expect(isValidDuration(NaN)).toBe(false);
      expect(isValidDuration(Infinity)).toBe(false);
      expect(isValidDuration(0)).toBe(false);
      expect(isValidDuration(-5)).toBe(false);
      expect(isValidDuration(undefined)).toBe(false);
      expect(isValidDuration(12.5)).toBe(true);
    });
  });

  describe('getBufferedRanges', () => {
    it('serializes TimeRanges to a plain array', () => {
      const tr = {
        length: 2,
        start: (i: number) => [0, 30][i],
        end:   (i: number) => [10, 40][i]
      } as TimeRanges;
      const media = { buffered: tr } as HTMLMediaElement;
      expect(getBufferedRanges(media)).toEqual([{ start: 0, end: 10 }, { start: 30, end: 40 }]);
    });
  });

  describe('enableHlsJsPlayerForCodecs', () => {
    it('forces hls.js for HEVC / AV1 / VP9 even when native HLS is available', () => {
      expect(enableHlsJsPlayerForCodecs(['hevc'], true)).toBe(true);
      expect(enableHlsJsPlayerForCodecs(['av1'], true)).toBe(true);
    });

    it('uses native HLS for h264 when supported', () => {
      expect(enableHlsJsPlayerForCodecs(['h264'], true)).toBe(false);
    });

    it('always falls back to hls.js when no native HLS', () => {
      expect(enableHlsJsPlayerForCodecs(['h264'], false)).toBe(true);
    });
  });

  describe('playWithPromise', () => {
    it('resolves when play() resolves', async () => {
      const video = document.createElement('video');
      vi.spyOn(video, 'play').mockResolvedValue();
      await expect(playWithPromise(video)).resolves.toBeUndefined();
    });

    it('rejects with the original error on NotAllowedError', async () => {
      const video = document.createElement('video');
      const err = Object.assign(new Error('autoplay blocked'), { name: 'NotAllowedError' });
      vi.spyOn(video, 'play').mockRejectedValue(err);
      const spy = vi.spyOn(console, 'warn').mockImplementation(() => {});
      await expect(playWithPromise(video)).rejects.toThrow('autoplay blocked');
      spy.mockRestore();
    });
  });

  describe('describeMediaError', () => {
    it('maps standard codes to human-readable strings', () => {
      expect(describeMediaError({ code: 4, message: '' } as MediaError)).toMatch(/not supported/);
      expect(describeMediaError({ code: 3, message: '' } as MediaError)).toMatch(/decoder/);
    });

    it('handles null gracefully', () => {
      expect(describeMediaError(null)).toBe('unknown media error');
    });
  });
});
