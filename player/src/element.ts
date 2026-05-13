import { Player, PlayerOptions } from './player';

/**
 * <jellyfin-player src="..." reporter-url="..." autoplay></jellyfin-player>
 *
 * Drop-in custom element wrapper. The Rails view helper renders this so server-
 * side templates can ship a working player without writing any JS.
 */
export class JellyfinPlayerElement extends HTMLElement {
  private player: Player | null = null;

  static get observedAttributes(): string[] {
    return ['src', 'autoplay', 'controls', 'volume', 'reporter-url'];
  }

  connectedCallback(): void {
    if (this.player) return;
    const src = this.getAttribute('src');
    if (!src) {
      console.error('[jellyfin-player] missing required "src" attribute');
      return;
    }
    const opts: PlayerOptions = {
      source: { hlsUrl: src },
      autoplay: this.hasAttribute('autoplay'),
      controls: this.getAttribute('controls') !== 'false',
      volume: this.getAttribute('volume') ? Number(this.getAttribute('volume')) : undefined
    };
    if (this.getAttribute('reporter-url')) {
      // Lazy-load to keep the element tiny when reporters aren't needed.
      import('./extensions/reporter').then(({ httpReporter }) => {
        opts.reporter = httpReporter(this.getAttribute('reporter-url')!);
        this.player = new Player(this, opts);
        this.player.load();
      });
    } else {
      this.player = new Player(this, opts);
      this.player.load();
    }
  }

  disconnectedCallback(): void {
    this.player?.destroy();
    this.player = null;
  }

  /** Access the underlying Player for advanced wiring. */
  getPlayer(): Player | null {
    return this.player;
  }
}

let registered = false;
export function registerJellyfinPlayer(): void {
  if (registered) return;
  if (typeof customElements === 'undefined') return;
  if (customElements.get('jellyfin-player')) return;
  customElements.define('jellyfin-player', JellyfinPlayerElement);
  registered = true;
}
