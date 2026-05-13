/**
 * Tiny typed event bus. Mirrors jellyfin-web/src/utils/events.ts but without the
 * legacy "trigger on `this`" convention — listeners just register with `.on()`.
 *
 * Used by Player to expose playback lifecycle to host applications.
 */
export type PlayerEvent =
  | 'ready'
  | 'play'
  | 'pause'
  | 'progress'
  | 'seek'
  | 'ratechange'
  | 'volumechange'
  | 'ended'
  | 'error'
  | 'waiting'
  | 'audiotrackchange'
  | 'subtitletrackchange'
  | 'chapter';

export type PlayerEventPayload = {
  ready: void;
  play: void;
  pause: void;
  progress: { currentTime: number; duration: number; buffered: number };
  seek: { currentTime: number };
  ratechange: { rate: number };
  volumechange: { volume: number; muted: boolean };
  ended: void;
  error: { code?: number; message: string };
  waiting: void;
  audiotrackchange: { id: string | number };
  subtitletrackchange: { id: string | number | null };
  chapter: { index: number; chapter: { startTime: number; endTime?: number; title?: string } };
};

type Listener<K extends PlayerEvent> = (payload: PlayerEventPayload[K]) => void;

export class EventBus {
  private listeners = new Map<PlayerEvent, Set<Listener<PlayerEvent>>>();

  on<K extends PlayerEvent>(event: K, fn: Listener<K>): () => void {
    if (!this.listeners.has(event)) this.listeners.set(event, new Set());
    this.listeners.get(event)!.add(fn as Listener<PlayerEvent>);
    return () => this.off(event, fn);
  }

  off<K extends PlayerEvent>(event: K, fn: Listener<K>): void {
    this.listeners.get(event)?.delete(fn as Listener<PlayerEvent>);
  }

  emit<K extends PlayerEvent>(event: K, payload: PlayerEventPayload[K]): void {
    this.listeners.get(event)?.forEach((fn) => {
      try {
        (fn as Listener<K>)(payload);
      } catch (e) {
        // Listener errors must not break the player.
        console.error(`[jellyfin-rails/player] listener error on '${event}':`, e);
      }
    });
  }
}
