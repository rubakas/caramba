import { EventBus } from '../event-bus';
import { TrackProvider, Chapter } from '../extensions/track-provider';
import { injectStyles } from './styles';
import { getBufferedRanges } from '../media-helper';

/**
 * Built-in control bar. Renders:
 *  - scrubber with progress, buffered, hover trickplay preview, chapter ticks
 *  - play/pause, skip ±10s, volume, time readout
 *  - track menu (subtitles / audio / quality)
 *  - fullscreen toggle
 *
 * Hosts that don't want this can pass `controls: false` to the Player and
 * mount their own DOM into the slot regions instead.
 */
export interface ControlsHandle {
  root: HTMLElement;
  openMenu(name: 'subtitle' | 'audio' | 'quality'): void;
  destroy(): void;
}

export interface ControlsOptions {
  video: HTMLVideoElement;
  events: EventBus;
  trackProvider: TrackProvider;
  onSubtitlePick(id: string | number | null): void;
  onAudioPick(id: string | number): void;
}

export function buildControls(host: HTMLElement, opts: ControlsOptions): ControlsHandle {
  injectStyles();

  const { video, events, trackProvider } = opts;

  const root = document.createElement('div');
  root.className = 'jellyfin-controls';
  host.appendChild(root);

  // --- scrubber ---
  const scrubber = document.createElement('div');
  scrubber.className = 'jellyfin-scrubber';
  const track    = document.createElement('div'); track.className    = 'jellyfin-scrubber-track';
  const buffer   = document.createElement('div'); buffer.className   = 'jellyfin-scrubber-buffer';
  const progress = document.createElement('div'); progress.className = 'jellyfin-scrubber-progress';
  const thumb    = document.createElement('div'); thumb.className    = 'jellyfin-scrubber-thumb';
  scrubber.append(track, buffer, progress, thumb);
  root.appendChild(scrubber);

  // --- trickplay preview tile ---
  const trickplay = document.createElement('div');
  trickplay.className = 'jellyfin-trickplay';
  scrubber.appendChild(trickplay);

  // --- bottom row ---
  const row = document.createElement('div');
  row.className = 'jellyfin-row';
  root.appendChild(row);

  const btnPlay     = mkButton(row, '▶',  () => video.paused ? video.play() : video.pause());
  const btnSkipBack = mkButton(row, '⏪',  () => { video.currentTime = Math.max(0, video.currentTime - 10); });
  const btnSkipFwd  = mkButton(row, '⏩',  () => { video.currentTime = Math.min(video.duration || 1e9, video.currentTime + 10); });

  const time = document.createElement('span');
  time.className = 'jellyfin-time';
  time.textContent = '0:00 / 0:00';
  row.appendChild(time);

  row.appendChild(spacer());

  // --- track menus ---
  let openMenu: HTMLElement | null = null;
  const closeOpen = () => { if (openMenu) { openMenu.dataset.open = 'false'; openMenu = null; } };

  const subMenu     = buildMenu(host, 'subtitle');
  const audioMenu   = buildMenu(host, 'audio');
  mkButton(row, 'CC', () => toggleMenu(subMenu));
  mkButton(row, '🔊', () => toggleMenu(audioMenu));
  mkButton(row, '⛶',  () => toggleFullscreen(host));

  function toggleMenu(m: HTMLElement) {
    const willOpen = openMenu !== m;
    closeOpen();
    if (willOpen) { m.dataset.open = 'true'; openMenu = m; }
  }
  scrubber.addEventListener('click', closeOpen);

  // Populate menus once tracks are known.
  refreshMenus();

  // --- scrubber interaction ---
  let dragging = false;
  const ratioFromEvent = (e: MouseEvent) => {
    const r = scrubber.getBoundingClientRect();
    return Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  };

  scrubber.addEventListener('mousedown', (e) => {
    dragging = true;
    thumb.dataset.active = 'true';
    seekFromRatio(ratioFromEvent(e));
  });
  window.addEventListener('mousemove', (e) => {
    const ratio = ratioFromEvent(e);
    updateTrickplay(e, ratio);
    if (dragging) seekFromRatio(ratio);
  });
  window.addEventListener('mouseup', () => {
    dragging = false;
    thumb.dataset.active = 'false';
  });
  scrubber.addEventListener('mouseleave', () => { trickplay.dataset.active = 'false'; });
  scrubber.addEventListener('mousemove', (e) => {
    const ratio = ratioFromEvent(e);
    updateTrickplay(e, ratio);
  });

  function seekFromRatio(ratio: number) {
    const dur = video.duration;
    if (Number.isFinite(dur) && dur > 0) video.currentTime = ratio * dur;
  }

  function updateTrickplay(e: MouseEvent, ratio: number) {
    if (!trackProvider.getTrickplayUrl) return;
    const dur = video.duration;
    if (!Number.isFinite(dur) || dur <= 0) return;
    const ticks = ratio * dur;
    const url = trackProvider.getTrickplayUrl(ticks);
    if (!url) return;
    trickplay.style.backgroundImage = `url(${JSON.stringify(url)})`;
    const r = scrubber.getBoundingClientRect();
    trickplay.style.left = `${e.clientX - r.left}px`;
    trickplay.dataset.active = 'true';
  }

  // --- chapter ticks ---
  let chapterTicks: HTMLElement[] = [];
  let chapters: Chapter[] = [];

  async function renderChapters() {
    chapterTicks.forEach((t) => t.remove());
    chapterTicks = [];
    chapters = (await trackProvider.getChapters?.()) ?? [];
    const dur = video.duration;
    if (!Number.isFinite(dur) || dur <= 0) return;
    chapters.forEach((c) => {
      const tick = document.createElement('div');
      tick.className = 'jellyfin-chapter-tick';
      tick.style.left = `${(c.startTime / dur) * 100}%`;
      tick.title = c.title ?? '';
      scrubber.appendChild(tick);
      chapterTicks.push(tick);
    });
  }

  let lastChapterIndex = -1;
  function checkChapterCrossing() {
    if (!chapters.length) return;
    const t = video.currentTime;
    // Reverse-scan to find the highest-indexed chapter whose start ≤ t.
    let i = -1;
    for (let k = chapters.length - 1; k >= 0; k--) {
      if (t >= chapters[k].startTime) { i = k; break; }
    }
    if (i !== lastChapterIndex && i >= 0) {
      lastChapterIndex = i;
      events.emit('chapter', { index: i, chapter: chapters[i] });
    }
  }

  // --- frame loop ---
  const tick = () => {
    if (!Number.isFinite(video.duration) || video.duration <= 0) {
      time.textContent = '0:00 / 0:00';
    } else {
      const pct = (video.currentTime / video.duration) * 100;
      progress.style.width = `${pct}%`;
      thumb.style.left = `${pct}%`;
      const ranges = getBufferedRanges(video);
      const last = ranges.length ? ranges[ranges.length - 1].end : 0;
      buffer.style.width = `${(last / video.duration) * 100}%`;
      time.textContent = `${formatTime(video.currentTime)} / ${formatTime(video.duration)}`;
      checkChapterCrossing();
    }
    raf = requestAnimationFrame(tick);
  };
  let raf = requestAnimationFrame(tick);

  // --- play/pause icon swap ---
  video.addEventListener('play',  () => { btnPlay.textContent = '⏸'; });
  video.addEventListener('pause', () => { btnPlay.textContent = '▶';  });

  // --- auto-hide on idle ---
  let idleTimer: number | null = null;
  const armIdle = () => {
    host.dataset.controlsIdle = 'false';
    if (idleTimer !== null) clearTimeout(idleTimer);
    idleTimer = window.setTimeout(() => { host.dataset.controlsIdle = 'true'; }, 3000);
  };
  host.addEventListener('mousemove', armIdle);
  host.addEventListener('mouseleave', () => { host.dataset.controlsIdle = 'true'; });
  armIdle();

  // --- track menu refresh on metadata load ---
  video.addEventListener('loadedmetadata', () => {
    refreshMenus();
    renderChapters();
  });

  async function refreshMenus() {
    populateMenu(subMenu, 'subtitle');
    populateMenu(audioMenu, 'audio');
  }

  async function populateMenu(menu: HTMLElement, kind: 'subtitle' | 'audio') {
    menu.replaceChildren();
    if (kind === 'subtitle') {
      const tracks = (await trackProvider.getSubtitleTracks?.()) ?? [];
      menu.appendChild(mkMenuItem('Off', () => opts.onSubtitlePick(null)));
      tracks.forEach((t) => menu.appendChild(mkMenuItem(t.label ?? t.language ?? `#${t.id}`,
                                                        () => opts.onSubtitlePick(t.id))));
    } else {
      const tracks = (await trackProvider.getAudioTracks?.()) ?? [];
      tracks.forEach((t) => menu.appendChild(mkMenuItem(t.label ?? t.language ?? `#${t.id}`,
                                                        () => opts.onAudioPick(t.id))));
    }
  }

  return {
    root,
    openMenu(name) {
      if (name === 'subtitle') toggleMenu(subMenu);
      else if (name === 'audio') toggleMenu(audioMenu);
    },
    destroy() {
      cancelAnimationFrame(raf);
      if (idleTimer !== null) clearTimeout(idleTimer);
      root.remove();
      subMenu.remove();
      audioMenu.remove();
    }
  };
}

// --- helpers ---

function mkButton(parent: HTMLElement, label: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement('button');
  b.textContent = label;
  b.addEventListener('click', onClick);
  parent.appendChild(b);
  return b;
}

function spacer(): HTMLElement {
  const s = document.createElement('span');
  s.className = 'jellyfin-spacer';
  return s;
}

function buildMenu(host: HTMLElement, kind: 'subtitle' | 'audio'): HTMLElement {
  const m = document.createElement('div');
  m.className = `jellyfin-menu jellyfin-menu--${kind}`;
  m.dataset.open = 'false';
  host.appendChild(m);
  return m;
}

function mkMenuItem(text: string, onClick: () => void): HTMLElement {
  const el = document.createElement('div');
  el.className = 'jellyfin-menu-item';
  el.textContent = text;
  el.addEventListener('click', onClick);
  return el;
}

function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = s % 60;
  return h > 0 ? `${h}:${pad(m)}:${pad(ss)}` : `${m}:${pad(ss)}`;
}

function pad(n: number): string {
  return n.toString().padStart(2, '0');
}

function toggleFullscreen(host: HTMLElement) {
  if (document.fullscreenElement) {
    document.exitFullscreen().catch(() => {});
  } else {
    host.requestFullscreen?.().catch(() => {});
  }
}
