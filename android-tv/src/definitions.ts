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

// ── Native player ─────────────────────────────────────────────────────

export interface PlayerPresentOptions {
  sessionId: string;
  streamUrl: string | null;
  hlsUrl: string | null;
  subtitleUrl: string | null;
  strategy: 'direct_play' | 'direct_stream' | 'audio_transcode' | 'full_transcode';
  duration: number;
  startTime: number;
  seekBase: number;
  title?: string;
  subtitle?: string;
  audioStreams?: Array<{ index: number; language: string; codec: string; channels: number; title?: string | null }>;
  subtitleStreams?: Array<{ index: number; language: string; codec: string; isText: boolean; title?: string | null }>;
  activeAudioIndex?: number | null;
  activeSubtitleIndex?: number | null;
  isBitmapSubtitle?: boolean;
  video?: { codec: string; width: number; height: number; pix_fmt?: string; color_transfer?: string | null } | null;
}

export interface PlayerUpdateOptions {
  sessionId: string;
  streamUrl?: string | null;
  hlsUrl?: string | null;
  subtitleUrl?: string | null;
  seekBase?: number;
  strategy?: PlayerPresentOptions['strategy'];
  isBitmapSubtitle?: boolean;
  startTime?: number;
}

export interface PlayerProgressEvent { sessionId: string; position: number; duration: number; isPlaying: boolean; }
export interface PlayerReadyEvent    { sessionId: string; }
export interface PlayerSeekRequest   { sessionId: string; absoluteTime: number; }
export interface PlayerAudioSwitchRequest { sessionId: string; audioStreamIndex: number; currentVideoTime: number; }
export interface PlayerSubtitleSwitchRequest { sessionId: string; subtitleStreamIndex: number; isBitmap: boolean; currentVideoTime: number; }
export interface PlayerSubtitleAppearanceRequest { sessionId: string; subtitleSize?: string; subtitleStyle?: string; }
export interface PlayerEndedEvent    { sessionId: string; position: number; duration: number; }
export interface PlayerErrorEvent    { sessionId: string; code: number; message: string; recoverable: boolean; }
export interface PlayerDismissedEvent {
  sessionId: string;
  position: number;
  duration: number;
  reason: 'back' | 'home' | 'remote';
}

export interface CarambaPlayerPlugin {
  /** Feature-detect — JS uses this once at app start to decide whether to render the WebView <video> path. */
  isAvailable(): Promise<{ available: boolean }>;
  /** Open full-screen ExoPlayer with a /api/playback/start payload. Resolves immediately. */
  present(options: PlayerPresentOptions): Promise<void>;
  /** Swap stream/subtitle URLs mid-session after a server-side seek/audio/subtitle switch. */
  updateStream(options: PlayerUpdateOptions): Promise<void>;
  /** Local-only seek (only meaningful for direct_play; HLS strategies use requestSeek round-trip). */
  seekTo(options: { time: number }): Promise<void>;
  pause(): Promise<void>;
  play(): Promise<void>;
  /** Finish the player Activity programmatically (no `dismissed` event will fire). */
  dismiss(): Promise<void>;
  /** One-shot read of position/duration — used by closePlayer when JS initiated the close. */
  getState(): Promise<{ position: number; duration: number; paused: boolean; ended: boolean }>;
  addListener(eventName: 'progress',                  listener: (e: PlayerProgressEvent) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'ready',                     listener: (e: PlayerReadyEvent) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'requestSeek',               listener: (e: PlayerSeekRequest) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'requestAudioSwitch',        listener: (e: PlayerAudioSwitchRequest) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'requestSubtitleSwitch',     listener: (e: PlayerSubtitleSwitchRequest) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'requestSubtitleAppearance', listener: (e: PlayerSubtitleAppearanceRequest) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'ended',                     listener: (e: PlayerEndedEvent) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'error',                     listener: (e: PlayerErrorEvent) => void): Promise<PluginListenerHandle>;
  addListener(eventName: 'dismissed',                 listener: (e: PlayerDismissedEvent) => void): Promise<PluginListenerHandle>;
  removeAllListeners(): Promise<void>;
}

const CarambaSettings = registerPlugin<CarambaSettingsPlugin>('CarambaSettings', {
  web: () => import('./web').then(m => new m.CarambaSettingsWeb()),
});

const CarambaUpdater = registerPlugin<CarambaUpdaterPlugin>('CarambaUpdater', {
  web: () => import('./web').then(m => new m.CarambaUpdaterWeb()),
});

const CarambaPlayer = registerPlugin<CarambaPlayerPlugin>('CarambaPlayer', {
  web: () => import('./web').then(m => new m.CarambaPlayerWeb()),
});

export { CarambaSettings, CarambaUpdater, CarambaPlayer };
