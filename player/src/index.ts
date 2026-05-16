export { Player } from './player';
export type { PlayerOptions } from './player';
export { EventBus } from './event-bus';
export type { PlayerEvent, PlayerEventPayload } from './event-bus';
export { SlotRegistry, SLOT_NAMES } from './extensions/slots';
export type { SlotName } from './extensions/slots';
export { httpReporter } from './extensions/reporter';
export type { Reporter, ReporterState } from './extensions/reporter';
export type {
  TrackProvider,
  SubtitleTrack,
  AudioTrack,
  Chapter
} from './extensions/track-provider';
export { JellyfinPlayerElement, registerJellyfinPlayer } from './element';
export { activateSubtitleTrack, deactivateSubtitleTrack } from './subtitles';
export type { SubtitleHandle } from './subtitles';
export {
  loadAppearance, saveAppearance, vttCueCss
} from './subtitles/appearance';
export type { SubtitleAppearance } from './subtitles/appearance';
export {
  SUB_SIZES, SUB_STYLES, VIDEO_CLASS as PLAYER_VIDEO_CLASS, buildCueCss
} from './subtitles/presets';
export type { SubtitleSizePreset, SubtitleStylePreset } from './subtitles/presets';
export {
  getSavedVolume, saveVolume, isValidDuration, getBufferedRanges,
  enableHlsJsPlayerForCodecs, playWithPromise, describeMediaError,
  resolveUrl, shouldUsePrefetchHack
} from './media-helper';
export type { BufferedRange } from './media-helper';

export const VERSION = '0.0.1';

// Auto-register the custom element when imported in a browser context.
import { registerJellyfinPlayer } from './element';
if (typeof window !== 'undefined') registerJellyfinPlayer();
