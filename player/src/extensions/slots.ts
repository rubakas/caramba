/**
 * Named slot regions where a host can mount custom UI.
 *
 * Pattern mirrors web components <slot> but works without shadow DOM so hosts
 * can style with regular CSS. The Player exposes `mount(slot, element)` and
 * inserts elements into pre-defined regions in the player chrome.
 */
export type SlotName =
  | 'overlay-top'
  | 'overlay-bottom'
  | 'controls-left'
  | 'controls-center'
  | 'controls-right'
  | 'sidebar';

export const SLOT_NAMES: SlotName[] = [
  'overlay-top',
  'overlay-bottom',
  'controls-left',
  'controls-center',
  'controls-right',
  'sidebar'
];

export class SlotRegistry {
  private nodes = new Map<SlotName, HTMLElement>();

  attach(name: SlotName, node: HTMLElement): void {
    this.nodes.set(name, node);
  }

  mount(name: SlotName, child: HTMLElement | string): void {
    const slot = this.nodes.get(name);
    if (!slot) {
      console.warn(`[jellyfin-rails/player] unknown slot '${name}'`);
      return;
    }
    if (typeof child === 'string') {
      slot.innerHTML = child;
    } else {
      slot.appendChild(child);
    }
  }

  clear(name: SlotName): void {
    const slot = this.nodes.get(name);
    if (slot) slot.replaceChildren();
  }
}
