import { WebPlugin } from '@capacitor/core';

import type { CarambaSettingsPlugin, CarambaUpdaterPlugin, UpdateInfo } from './definitions';

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
