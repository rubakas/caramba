import { WebPlugin } from '@capacitor/core';

import type { CarambaSettingsPlugin } from './definitions';

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
