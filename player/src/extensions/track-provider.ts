/**
 * The TrackProvider lets the host application supply subtitle, audio, and
 * trickplay metadata without coupling the player to any specific backend.
 *
 * Mirrors the methods htmlVideoPlayer calls on jellyfin-web's apiClient +
 * playbackManager, surfaced as a single host-implementable interface.
 */
export interface SubtitleTrack {
  id: string | number;
  url: string;
  language?: string;
  label?: string;
  codec?: 'vtt' | 'srt' | 'ass' | 'ssa' | 'pgs';
  default?: boolean;
  forced?: boolean;
}

export interface AudioTrack {
  id: string | number;
  label?: string;
  language?: string;
  default?: boolean;
}

export interface Chapter {
  startTime: number;
  endTime?: number;
  title?: string;
}

export interface TrackProvider {
  getSubtitleTracks?(): SubtitleTrack[] | Promise<SubtitleTrack[]>;
  getAudioTracks?(): AudioTrack[] | Promise<AudioTrack[]>;
  getChapters?(): Chapter[] | Promise<Chapter[]>;
  getTrickplayUrl?(timeSeconds: number): string | null;
  getMaxBitrate?(): number | undefined;
}

export const NULL_TRACK_PROVIDER: TrackProvider = {};
