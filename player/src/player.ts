/**
 * Core Player class. Wraps an HTMLVideoElement + hls.js, exposes a stable
 * external API and lifecycle events, and surfaces extension hooks (event bus,
 * slots, track provider, reporter).
 *
 * The full jellyfin-web `htmlVideoPlayer/plugin.js` (2,229 LOC) handles many
 * additional concerns (PiP/AirPlay, custom VTT cue rendering, FLV, casting,
 * libass/libpgs, browser quirks). We port those incrementally in phase 4+.
 * This file holds the framework code those features plug into.
 */
import { EventBus, PlayerEvent, PlayerEventPayload } from './event-bus';
import {
  TrackProvider,
  NULL_TRACK_PROVIDER,
  SubtitleTrack,
  AudioTrack,
  Chapter
} from './extensions/track-provider';
import { Reporter, ReporterState } from './extensions/reporter';
import { SlotName, SlotRegistry, SLOT_NAMES } from './extensions/slots';
import { activateSubtitleTrack, deactivateSubtitleTrack, SubtitleHandle } from './subtitles';
import {
  bindHlsErrorRecovery, getSavedVolume, saveVolume, playWithPromise,
  describeMediaError, enableHlsJsPlayerForCodecs, seekOnPlaybackStart,
  resolveUrl, shouldUsePrefetchHack
} from './media-helper';
import { detectBrowser } from './browser';
import {
  hlsConfigForBrowser, installStallWatchdog, installVisibilityResume,
  bindBrowserSpecificHlsRecovery, createBlobUrlTracker, StallWatchdogHandle
} from './mse-workarounds';
import { buildControls, ControlsHandle } from './controls/controls';
import { injectStyles } from './controls/styles';

export interface PlayerOptions {
  /** Required: HLS playlist URL (e.g. /jellyfin/transcode/:token/master.m3u8). */
  source: { hlsUrl: string };
  /** Host-supplied tracks + chapters. */
  trackProvider?: TrackProvider;
  /** Host-supplied progress reporter. */
  reporter?: Reporter;
  /** Auto-load and start playback once metadata is ready. Default: false. */
  autoplay?: boolean;
  /** Initial volume [0,1]. Default: persisted value or 1.0. */
  volume?: number;
  /** Whether to render the built-in control bar. Default: true. */
  controls?: boolean;
  /** Progress event throttling, ms. Default: 1000. */
  progressIntervalMs?: number;
  /** Resume position in seconds — seeks once metadata is loaded. */
  startAtSeconds?: number;
  /** Enable Space / Arrow keyboard shortcuts. Default: true. */
  keyboardShortcuts?: boolean;
  /**
   * Start the video muted. Required for unattended autoplay in every
   * modern browser (Chrome, Firefox, Safari block `video.play()` for
   * unmuted videos without a user gesture). When set, the player unmutes
   * automatically once the first frame is decoded (`canplay` event) —
   * by then the playback has been authorised by the browser and unmute
   * doesn't pause the stream. Default: `true` when `autoplay`, else
   * `false`.
   */
  muted?: boolean;
}

export class Player {
  readonly events = new EventBus();
  readonly slots = new SlotRegistry();
  readonly options: PlayerOptions;

  private root: HTMLElement;
  private video: HTMLVideoElement;
  private hls: any | null = null;
  private trackProvider: TrackProvider;
  private reporter: Reporter | null;
  private progressTimer: number | null = null;
  private started = false;
  private subtitleHandle: SubtitleHandle | null = null;
  private controlsHandle: ControlsHandle | null = null;
  private subtitleTracks: import('./extensions/track-provider').SubtitleTrack[] = [];
  private audioTracks: import('./extensions/track-provider').AudioTrack[] = [];
  private stallWatchdog: StallWatchdogHandle | null = null;
  private removeVisibilityHook: (() => void) | null = null;
  private blobUrls = createBlobUrlTracker();

  constructor(mount: HTMLElement, options: PlayerOptions) {
    this.options = options;
    this.trackProvider = options.trackProvider ?? NULL_TRACK_PROVIDER;
    this.reporter = options.reporter ?? null;
    this.root = mount;
    this.video = this.buildShell();
    this.bindMediaEvents();
    if (this.options.keyboardShortcuts !== false) this.bindKeyboardShortcuts();
  }

  /* ---- public API ---- */

  async load(): Promise<void> {
    const url = this.options.source.hlsUrl;
    const supportsNative = this.video.canPlayType('application/vnd.apple.mpegurl') !== '';

    // Pick engine: native HLS for Safari + non-forced codecs; hls.js otherwise.
    const useHlsJs = enableHlsJsPlayerForCodecs([], supportsNative);
    const browser = detectBrowser();

    if (supportsNative && !useHlsJs) {
      // iOS/Safari HLS prefetch hack — fire an XHR HEAD so the connection is
      // warm and any redirects are resolved before `video.src` triggers the
      // native HLS engine. Cuts time-to-first-frame by 0.5–2s on iOS.
      const finalUrl = shouldUsePrefetchHack() ? await resolveUrl(url) : url;
      this.video.src = finalUrl;
    } else {
      const { default: Hls } = await import('hls.js');
      if (!Hls.isSupported()) {
        if (supportsNative) {
          this.video.src = url; // last-resort native
        } else {
          this.fail('hls.js not supported by this browser');
          return;
        }
      } else {
        // Browser-specific HLS.js config — Firefox/Edge need tighter buffer
        // bounds; Safari (when we force hls.js for HEVC/AV1) needs the tightest.
        this.hls = new Hls(hlsConfigForBrowser(browser));
        bindHlsErrorRecovery(this.hls, (msg) => this.fail(msg));
        bindBrowserSpecificHlsRecovery(this.hls, browser, (msg) => this.fail(msg));
        this.hls.loadSource(url);
        this.hls.attachMedia(this.video);
      }
    }

    // Stall watchdog — recover when playhead freezes without an `error` event
    // (Firefox does this more often than other browsers).
    this.stallWatchdog = installStallWatchdog(this.video, () => this.tryRecoverFromStall());

    // Visibility resume — Firefox suspends AudioContext / source-buffer updates
    // when the tab is hidden; on return, kick playback back.
    if (browser.isFirefox) {
      this.removeVisibilityHook = installVisibilityResume(this.video);
    }

    // Resume from a saved playback position once metadata is available.
    if (this.options.startAtSeconds && this.options.startAtSeconds > 0) {
      seekOnPlaybackStart(this.video, this.options.startAtSeconds);
    }

    await this.applySubtitleTracks();
    this.events.emit('ready', undefined);
    if (this.options.autoplay) playWithPromise(this.video).catch(() => {});
  }

  private bindKeyboardShortcuts(): void {
    // Bind on the player root so multiple players on the same page don't fight.
    this.root.tabIndex = 0; // focusable
    this.root.addEventListener('keydown', (e) => {
      // Skip if focus is on an input/textarea/contenteditable (don't hijack typing).
      const target = e.target as HTMLElement;
      if (target?.matches?.('input, textarea, [contenteditable="true"]')) return;
      switch (e.key) {
        case ' ':
        case 'k':
          this.video.paused ? this.video.play() : this.video.pause();
          e.preventDefault();
          break;
        case 'ArrowLeft':
          this.video.currentTime = Math.max(0, this.video.currentTime - 5);
          e.preventDefault();
          break;
        case 'ArrowRight':
          this.video.currentTime = Math.min(this.video.duration || 1e9, this.video.currentTime + 5);
          e.preventDefault();
          break;
        case 'ArrowUp':
          this.setVolume(this.video.volume + 0.05);
          e.preventDefault();
          break;
        case 'ArrowDown':
          this.setVolume(this.video.volume - 0.05);
          e.preventDefault();
          break;
        case 'm':
          this.video.muted = !this.video.muted;
          e.preventDefault();
          break;
        case 'f':
          if (document.fullscreenElement) {
            document.exitFullscreen().catch(() => {});
          } else {
            this.root.requestFullscreen?.().catch(() => {});
          }
          e.preventDefault();
          break;
        case 'j':
          this.video.currentTime = Math.max(0, this.video.currentTime - 10);
          e.preventDefault();
          break;
        case 'l':
          this.video.currentTime = Math.min(this.video.duration || 1e9, this.video.currentTime + 10);
          e.preventDefault();
          break;
      }
    });
  }

  /** Recovery path invoked by the stall watchdog. Cheap nudges first. */
  private tryRecoverFromStall(): void {
    if (this.hls) {
      // Most common Firefox stall: source-buffer update got stuck. Recover.
      try { this.hls.recoverMediaError(); return; } catch { /* fall through */ }
    }
    // Native HLS / fallback: a tiny seek nudge usually unblocks the playhead.
    const t = this.video.currentTime;
    if (Number.isFinite(t)) this.video.currentTime = t + 0.01;
  }

  /** Returns available HLS quality levels (when using hls.js engine). */
  getQualityLevels(): Array<{ id: number; height: number; bitrate: number }> {
    if (!this.hls?.levels) return [];
    return this.hls.levels.map((l: any, i: number) => ({
      id: i, height: l.height, bitrate: l.bitrate
    }));
  }

  /** Pick a quality level by id (from getQualityLevels). -1 = auto/ABR. */
  setQualityLevel(id: number): void {
    if (this.hls) this.hls.currentLevel = id;
  }

  play(): Promise<void> { return this.video.play(); }
  pause(): void { this.video.pause(); }
  seek(seconds: number): void { this.video.currentTime = seconds; }
  setVolume(v: number): void { this.video.volume = Math.max(0, Math.min(1, v)); }
  setPlaybackRate(r: number): void { this.video.playbackRate = r; }

  get currentTime(): number { return this.video.currentTime; }
  get duration(): number { return this.video.duration || 0; }
  get paused(): boolean { return this.video.paused; }
  get volume(): number { return this.video.volume; }
  get muted(): boolean { return this.video.muted; }

  on<K extends PlayerEvent>(event: K, fn: (payload: PlayerEventPayload[K]) => void): () => void {
    return this.events.on(event, fn);
  }

  mountSlot(name: SlotName, child: HTMLElement | string): void {
    this.slots.mount(name, child);
  }

  async getSubtitleTracks(): Promise<SubtitleTrack[]> {
    return (await this.trackProvider.getSubtitleTracks?.()) ?? [];
  }

  async getAudioTracks(): Promise<AudioTrack[]> {
    return (await this.trackProvider.getAudioTracks?.()) ?? [];
  }

  async getChapters(): Promise<Chapter[]> {
    return (await this.trackProvider.getChapters?.()) ?? [];
  }

  destroy(): void {
    this.video.pause();
    if (this.hls) {
      this.hls.destroy();
      this.hls = null;
    }
    if (this.progressTimer !== null) {
      clearInterval(this.progressTimer);
      this.progressTimer = null;
    }
    this.stallWatchdog?.stop();
    this.stallWatchdog = null;
    this.removeVisibilityHook?.();
    this.removeVisibilityHook = null;
    this.blobUrls.cleanup();
    this.controlsHandle?.destroy();
    this.controlsHandle = null;
    deactivateSubtitleTrack(this.subtitleHandle);
    this.subtitleHandle = null;
    this.emitReporter('onStop');
    this.root.replaceChildren();
  }

  /* ---- internals ---- */

  private buildShell(): HTMLVideoElement {
    injectStyles();
    this.root.classList.add('jellyfin-player');
    this.root.style.position = 'relative';

    const video = document.createElement('video');
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.display = 'block';
    video.style.backgroundColor = '#000';
    video.playsInline = true;
    // We render our own controls when options.controls !== false.
    video.controls = false;
    video.crossOrigin = 'anonymous';
    video.volume = this.options.volume ?? getSavedVolume();
    // Browser autoplay policy: unmuted `.play()` from JS gets rejected
    // without a prior user gesture. Default `muted: true` whenever
    // autoplay is on so playback can start; auto-unmute on `canplay`
    // below so the user still gets sound. Callers can opt out with
    // `muted: false` (e.g. for a player surface that's only ever
    // triggered by a click — though autoplay then becomes best-effort).
    video.muted = this.options.muted ?? !!this.options.autoplay;
    if (video.muted) {
      const unmute = () => { video.muted = false; video.removeEventListener('canplay', unmute); };
      video.addEventListener('canplay', unmute);
    }
    this.root.appendChild(video);

    // Pre-create slot regions overlaid on the video.
    SLOT_NAMES.forEach((name) => {
      const el = document.createElement('div');
      el.dataset.jellyfinSlot = name;
      el.className = `jellyfin-slot jellyfin-slot--${name}`;
      el.style.position = 'absolute';
      el.style.pointerEvents = 'none';
      this.root.appendChild(el);
      this.slots.attach(name, el);
    });

    if (this.options.controls !== false) {
      this.controlsHandle = buildControls(this.root, {
        video,
        events: this.events,
        trackProvider: this.trackProvider,
        onSubtitlePick: (id) => this.pickSubtitleById(id),
        onAudioPick:    (id) => this.pickAudioById(id)
      });
    }

    return video;
  }

  private async pickSubtitleById(id: string | number | null): Promise<void> {
    if (id === null) return this.setActiveSubtitleTrack(null);
    if (!this.subtitleTracks.length) {
      this.subtitleTracks = await this.getSubtitleTracks();
    }
    const track = this.subtitleTracks.find((t) => t.id === id);
    await this.setActiveSubtitleTrack(track ?? null);
  }

  private async pickAudioById(id: string | number): Promise<void> {
    if (!this.audioTracks.length) {
      this.audioTracks = await this.getAudioTracks();
    }
    // For hls.js streams audio tracks are switchable via hls.audioTrack.
    if (this.hls) {
      const idx = this.audioTracks.findIndex((t) => t.id === id);
      if (idx >= 0) this.hls.audioTrack = idx;
    } else {
      // Native HTML5 audio track selection.
      const tracks = (this.video as any).audioTracks;
      if (tracks) {
        for (let i = 0; i < tracks.length; i++) tracks[i].enabled = (tracks[i].id === String(id) || i === Number(id));
      }
    }
    this.events.emit('audiotrackchange', { id });
  }

  private bindMediaEvents(): void {
    const v = this.video;

    v.addEventListener('play', () => {
      if (!this.started) {
        this.started = true;
        this.emitReporter('onStart');
      }
      this.events.emit('play', undefined);
      this.startProgressTimer();
    });
    v.addEventListener('pause', () => {
      this.events.emit('pause', undefined);
      this.stopProgressTimer();
    });
    v.addEventListener('seeked', () => this.events.emit('seek', { currentTime: v.currentTime }));
    v.addEventListener('ratechange', () => this.events.emit('ratechange', { rate: v.playbackRate }));
    v.addEventListener('volumechange', () => {
      saveVolume(v.volume);
      this.events.emit('volumechange', { volume: v.volume, muted: v.muted });
    });
    v.addEventListener('waiting', () => this.events.emit('waiting', undefined));
    v.addEventListener('ended', () => {
      this.stopProgressTimer();
      this.emitReporter('onStop');
      this.events.emit('ended', undefined);
    });
    v.addEventListener('error', () => {
      const code = v.error?.code;
      const message = describeMediaError(v.error);
      this.events.emit('error', { code, message });
      this.emitReporter('onError', { message, code });
    });
  }

  private startProgressTimer(): void {
    if (this.progressTimer !== null) return;
    const ms = this.options.progressIntervalMs ?? 1000;
    this.progressTimer = window.setInterval(() => this.fireProgress(), ms);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer !== null) {
      clearInterval(this.progressTimer);
      this.progressTimer = null;
    }
  }

  private fireProgress(): void {
    const buffered = this.video.buffered.length ? this.video.buffered.end(this.video.buffered.length - 1) : 0;
    this.events.emit('progress', {
      currentTime: this.video.currentTime,
      duration: this.video.duration || 0,
      buffered
    });
    this.emitReporter('onProgress');
  }

  private async applySubtitleTracks(): Promise<void> {
    const tracks = await this.getSubtitleTracks();
    const initial = tracks.find((t) => t.default) ?? tracks[0];
    if (initial) await this.setActiveSubtitleTrack(initial);
  }

  async setActiveSubtitleTrack(track: SubtitleTrack | null): Promise<void> {
    deactivateSubtitleTrack(this.subtitleHandle);
    this.subtitleHandle = null;
    if (track) {
      this.subtitleHandle = await activateSubtitleTrack(this.video, track);
    }
    this.events.emit('subtitletrackchange', { id: track?.id ?? null });
  }

  private emitReporter(method: 'onStart' | 'onProgress' | 'onStop'): void;
  private emitReporter(method: 'onError', err: { message: string; code?: number }): void;
  private emitReporter(method: string, err?: { message: string; code?: number }): void {
    if (!this.reporter) return;
    const state: ReporterState = {
      currentTime: this.video.currentTime,
      duration: this.video.duration || 0,
      paused: this.video.paused,
      rate: this.video.playbackRate,
      volume: this.video.volume,
      muted: this.video.muted
    };
    try {
      if (method === 'onError') this.reporter.onError?.(err!, state);
      else if (method === 'onStart') this.reporter.onStart?.(state);
      else if (method === 'onProgress') this.reporter.onProgress?.(state);
      else if (method === 'onStop') this.reporter.onStop?.(state);
    } catch {
      // Reporter errors must not break playback.
    }
  }

  private fail(message: string): void {
    this.events.emit('error', { message });
    this.emitReporter('onError', { message });
  }
}
