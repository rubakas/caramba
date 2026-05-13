/**
 * Minimal scoped CSS for the built-in control bar. Injected once at the first
 * Player construction. Host apps can override by targeting the `.jellyfin-*`
 * classes — nothing is shadow DOM, so cascade is intentional.
 */
const CSS = `
.jellyfin-player { position: relative; overflow: hidden; user-select: none; }
.jellyfin-player video { background: #000; }

.jellyfin-controls {
  position: absolute; left: 0; right: 0; bottom: 0;
  background: linear-gradient(to top, rgba(0,0,0,0.85), rgba(0,0,0,0));
  color: #fff; padding: 1rem 1rem 0.75rem; display: flex; flex-direction: column;
  font-family: system-ui, -apple-system, sans-serif; font-size: 14px;
  transition: opacity 200ms ease; opacity: 1;
}
.jellyfin-player[data-controls-idle="true"] .jellyfin-controls { opacity: 0; }

.jellyfin-scrubber { position: relative; height: 10px; cursor: pointer; flex: 0 0 auto; }
.jellyfin-scrubber-track {
  position: absolute; left: 0; right: 0; top: 4px; height: 2px;
  background: rgba(255,255,255,0.3); border-radius: 1px;
}
.jellyfin-scrubber-buffer {
  position: absolute; left: 0; top: 4px; height: 2px;
  background: rgba(255,255,255,0.5); border-radius: 1px;
}
.jellyfin-scrubber-progress {
  position: absolute; left: 0; top: 4px; height: 2px;
  background: var(--jellyfin-accent, #00a4dc); border-radius: 1px;
}
.jellyfin-scrubber-thumb {
  position: absolute; top: 0; width: 12px; height: 12px;
  background: var(--jellyfin-accent, #00a4dc);
  border-radius: 50%; transform: translateX(-50%);
  opacity: 0; transition: opacity 200ms;
}
.jellyfin-scrubber:hover .jellyfin-scrubber-thumb,
.jellyfin-scrubber-thumb[data-active="true"] { opacity: 1; }

.jellyfin-chapter-tick {
  position: absolute; top: 3px; width: 2px; height: 4px;
  background: rgba(255,255,255,0.7);
}

.jellyfin-trickplay {
  position: absolute; bottom: 14px; transform: translateX(-50%);
  width: 160px; height: 90px; background: #000;
  border: 1px solid rgba(255,255,255,0.3); border-radius: 4px;
  background-size: cover; background-position: center; pointer-events: none;
  opacity: 0; transition: opacity 150ms;
}
.jellyfin-scrubber:hover ~ .jellyfin-trickplay,
.jellyfin-trickplay[data-active="true"] { opacity: 1; }

.jellyfin-row { display: flex; align-items: center; gap: 1rem; margin-top: 0.5rem; }
.jellyfin-controls button {
  background: transparent; border: none; color: inherit; cursor: pointer;
  padding: 0.25rem 0.5rem; font: inherit; opacity: 0.85;
}
.jellyfin-controls button:hover { opacity: 1; }
.jellyfin-controls .jellyfin-time { font-variant-numeric: tabular-nums; opacity: 0.85; }
.jellyfin-controls .jellyfin-spacer { flex: 1; }

.jellyfin-menu {
  position: absolute; right: 1rem; bottom: 3.5rem;
  background: rgba(20,20,20,0.95); border-radius: 6px; padding: 0.5rem 0;
  min-width: 180px; box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  display: none;
}
.jellyfin-menu[data-open="true"] { display: block; }
.jellyfin-menu-item {
  display: block; padding: 0.5rem 1rem; cursor: pointer; color: #fff;
  font-size: 13px; white-space: nowrap;
}
.jellyfin-menu-item:hover { background: rgba(255,255,255,0.1); }
.jellyfin-menu-item[data-selected="true"]::before {
  content: '✓ '; margin-left: -1rem;
}

.jellyfin-slot { z-index: 1; }
.jellyfin-slot.jellyfin-slot--overlay-top    { top: 0; left: 0; right: 0; }
.jellyfin-slot.jellyfin-slot--overlay-bottom { bottom: 4rem; left: 0; right: 0; }
.jellyfin-slot.jellyfin-slot--sidebar        { top: 0; right: 0; bottom: 0; width: 0; }
`;

let injected = false;

export function injectStyles(): void {
  if (injected) return;
  if (typeof document === 'undefined') return;
  const tag = document.createElement('style');
  tag.dataset.jellyfinPlayer = '';
  tag.textContent = CSS;
  document.head.appendChild(tag);
  injected = true;
}
