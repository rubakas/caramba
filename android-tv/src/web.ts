import { WebPlugin } from '@capacitor/core';

import type {
  CarambaSettingsPlugin,
  CarambaUpdaterPlugin,
  UpdateInfo,
  CarambaPlayerPlugin,
} from './definitions';

export class CarambaSettingsWeb extends WebPlugin implements CarambaSettingsPlugin {
  private readonly STORAGE_KEY = 'caramba_api_url';
  private readonly DEFAULT_URL = 'http://localhost:3001';

  async getApiUrl(): Promise<{ url: string }> {
    const url = localStorage.getItem(this.STORAGE_KEY) || this.DEFAULT_URL;
    return { url };
  }

  async setApiUrl(options: { url: string }): Promise<void> {
    if (!options.url) {
      throw new Error('URL is required');
    }
    localStorage.setItem(this.STORAGE_KEY, options.url);
  }
}

/**
 * Web fallback for the updater plugin.
 * In web environment, updates are not supported — all methods are no-ops.
 */
export class CarambaUpdaterWeb extends WebPlugin implements CarambaUpdaterPlugin {
  async checkForUpdate(): Promise<UpdateInfo | null> {
    // Updates not available in web mode
    return null;
  }

  async downloadUpdate(): Promise<{ ok: boolean; error?: string }> {
    return { ok: false, error: 'Updates not available in web mode' };
  }

  async installUpdate(): Promise<{ ok: boolean; error?: string }> {
    return { ok: false, error: 'Updates not available in web mode' };
  }
}

/**
 * Web fallback for the native player plugin. The native plugin only exists
 * inside the Capacitor Android build; in web (regular Chrome / laptop dev),
 * `isAvailable()` reports false so the React layer falls back to the
 * existing <video> + hls.js path.
 */
export class CarambaPlayerWeb extends WebPlugin implements CarambaPlayerPlugin {
  async isAvailable() { return { available: false }; }
  async present()      { throw this.unimplemented('present is native-only'); }
  async updateStream() { throw this.unimplemented('updateStream is native-only'); }
  async seekTo()       { throw this.unimplemented('seekTo is native-only'); }
  async pause()        { throw this.unimplemented('pause is native-only'); }
  async play()         { throw this.unimplemented('play is native-only'); }
  async dismiss()      { /* no-op in web */ }
  async getState()     { return { position: 0, duration: 0, paused: true, ended: false }; }
}
