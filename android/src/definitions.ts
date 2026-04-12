import { registerPlugin } from '@capacitor/core';

export interface CarambaSettingsPlugin {
  getApiUrl(): Promise<{ url: string }>;
  setApiUrl(options: { url: string }): Promise<void>;
}

const CarambaSettings = registerPlugin<CarambaSettingsPlugin>('CarambaSettings', {
  web: () => import('./web').then(m => new m.CarambaSettingsWeb()),
});

export * from './definitions';
export { CarambaSettings };
