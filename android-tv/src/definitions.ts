import { registerPlugin, PluginListenerHandle } from '@capacitor/core';

export interface CarambaSettingsPlugin {
  getApiUrl(): Promise<{ url: string }>;
  setApiUrl(options: { url: string }): Promise<void>;
}

export interface UpdateInfo {
  version: string;
  assetUrl: string;
  assetName: string;
  sha256: string | null;
}

export interface DownloadProgress {
  percent: number;
  downloaded: number;
  total: number;
}

export interface CarambaUpdaterPlugin {
  /** Check GitHub releases for a newer version */
  checkForUpdate(): Promise<UpdateInfo | null>;
  /** Download the update APK to cache directory */
  downloadUpdate(): Promise<{ ok: boolean; error?: string }>;
  /** Install the downloaded APK (triggers system installer) */
  installUpdate(): Promise<{ ok: boolean; error?: string }>;
  /** Listen for download progress events */
  addListener(
    eventName: 'downloadProgress',
    listener: (progress: DownloadProgress) => void
  ): Promise<PluginListenerHandle>;
  /** Remove all listeners */
  removeAllListeners(): Promise<void>;
}

const CarambaSettings = registerPlugin<CarambaSettingsPlugin>('CarambaSettings', {
  web: () => import('./web').then(m => new m.CarambaSettingsWeb()),
});

const CarambaUpdater = registerPlugin<CarambaUpdaterPlugin>('CarambaUpdater', {
  web: () => import('./web').then(m => new m.CarambaUpdaterWeb()),
});

export { CarambaSettings, CarambaUpdater };
