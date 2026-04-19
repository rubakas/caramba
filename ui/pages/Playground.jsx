import { useState, useCallback, useRef, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { refractive, lip, convex, concave, convexCircle } from '../config/refractive'
import { getAllGlassDefaults, getGlassBaseDefaults } from '../config/useGlassConfig'

const SURFACE_FNS = { lip, convex, concave, convexCircle }

// Load from glass.json (central config)
const GLASS_RESOLVED = getAllGlassDefaults()  // merged: defaults + per-specimen
const GLASS_BASE = getGlassBaseDefaults()     // just the defaults section

// All specimens from the codebase
const SPECIMENS = [
  {
    id: 'navbar',
    label: 'Navbar',
    element: 'nav',
    description: 'Top navigation bar (full-width, sharp corners)',
    render: (props) => (
      <refractive.nav style={{ width: '100%', height: 48, display: 'flex', alignItems: 'center', padding: '0 16px', background: 'rgba(255,255,255,0.08)', color: '#fff', fontSize: 14, fontWeight: 600 }} refraction={props}>
        Caramba &nbsp;&middot;&nbsp; Library &nbsp;&middot;&nbsp; Movies
      </refractive.nav>
    ),
  },
  {
    id: 'now-playing',
    label: 'Now Playing Bar',
    element: 'div',
    description: 'Persistent now-playing status bar',
    render: (props) => (
      <refractive.div style={{ width: 360, height: 48, display: 'flex', alignItems: 'center', padding: '0 16px', background: 'rgba(255,255,255,0.1)', border: '1px solid rgba(255,255,255,0.08)', color: '#fff', fontSize: 13 }} refraction={props}>
        <span style={{ opacity: 0.6, marginRight: 8 }}>Now Playing:</span> S03E07 &mdash; "Treehouse of Horror II"
      </refractive.div>
    ),
  },
  {
    id: 'toast',
    label: 'Toast Notification',
    element: 'div',
    description: 'Dismissable toast pill',
    render: (props) => (
      <refractive.div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '10px 20px', background: 'rgba(255,255,255,0.1)', border: '1px solid rgba(255,255,255,0.08)', color: '#fff', fontSize: 13 }} refraction={props}>
        <span style={{ color: '#4ade80' }}>&#10003;</span> Episode marked as watched
      </refractive.div>
    ),
  },
  {
    id: 'rating-badge',
    label: 'Rating Badge',
    element: 'span',
    description: 'Small poster card rating overlay (uses lip)',
    render: (props) => (
      <refractive.span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', padding: '3px 8px', background: 'rgba(0,0,0,0.55)', color: '#fff', fontSize: 12, fontWeight: 700, minWidth: 36 }} refraction={props}>
        8.9
      </refractive.span>
    ),
  },
  {
    id: 'popover',
    label: 'Episode Popover',
    element: 'div',
    description: 'Context menu popover (subtle glass)',
    render: (props) => (
      <refractive.div style={{ width: 200, padding: '6px 0', background: 'rgba(30,30,30,0.85)', border: '1px solid rgba(255,255,255,0.1)', color: '#fff', fontSize: 13 }} refraction={props}>
        {['Mark Watched', 'Open in VLC', 'Open in Default Player'].map((item) => (
          <div key={item} style={{ padding: '8px 14px', cursor: 'pointer' }}>{item}</div>
        ))}
      </refractive.div>
    ),
  },
  {
    id: 'update-prompt',
    label: 'Update Prompt',
    element: 'div',
    description: 'App update notification card',
    render: (props) => (
      <refractive.div style={{ width: 320, padding: 16, background: 'rgba(255,255,255,0.1)', border: '1px solid rgba(255,255,255,0.08)', color: '#fff', fontSize: 13 }} refraction={props}>
        <div style={{ fontWeight: 600, marginBottom: 8 }}>Update Available</div>
        <div style={{ opacity: 0.6, marginBottom: 12 }}>Version 1.1.0 is ready to install.</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button style={{ padding: '6px 14px', background: 'rgba(255,255,255,0.15)', border: '1px solid rgba(255,255,255,0.2)', color: '#fff', cursor: 'pointer', fontSize: 12 }}>Later</button>
          <button style={{ padding: '6px 14px', background: '#fff', border: 'none', color: '#000', cursor: 'pointer', fontSize: 12, fontWeight: 600 }}>Update Now</button>
        </div>
      </refractive.div>
    ),
  },
  {
    id: 'close-btn',
    label: 'Close Button',
    element: 'button',
    description: 'Video player close button (32x32 circle, lip)',
    render: (props) => (
      <refractive.button style={{ width: 32, height: 32, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.16)', border: '1px solid rgba(255,255,255,0.18)', color: '#fff', cursor: 'pointer' }} refraction={props}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </refractive.button>
    ),
  },
  {
    id: 'skip-btn',
    label: 'Skip Button',
    element: 'button',
    description: 'Skip back/forward button (48x48 circle, lip)',
    render: (props) => (
      <refractive.button style={{ width: 48, height: 48, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.16)', border: '1px solid rgba(255,255,255,0.18)', color: '#fff', cursor: 'pointer', position: 'relative' }} refraction={props}>
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/></svg>
        <span style={{ position: 'absolute', fontSize: 9, fontWeight: 700 }}>10</span>
      </refractive.button>
    ),
  },
  {
    id: 'play-btn',
    label: 'Play/Pause Button',
    element: 'button',
    description: 'Large play/pause button (72x72 circle, lip)',
    render: (props) => (
      <refractive.button style={{ width: 72, height: 72, display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'rgba(255,255,255,0.18)', border: '1px solid rgba(255,255,255,0.2)', color: '#fff', cursor: 'pointer' }} refraction={props}>
        <svg width="36" height="36" viewBox="0 0 24 24" fill="currentColor"><polygon points="6 3 20 12 6 21"/></svg>
      </refractive.button>
    ),
  },
  {
    id: 'utility-pill',
    label: 'Utility Pill',
    element: 'div',
    description: 'Video player utility controls group',
    render: (props) => (
      <refractive.div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '4px 6px', background: 'rgba(255,255,255,0.1)', border: '1px solid rgba(255,255,255,0.08)', color: 'rgba(255,255,255,0.85)', fontSize: 13 }} refraction={props}>
        <input type="range" min={0} max={1} step={0.05} defaultValue={0.7} style={{ width: 64, height: 3, accentColor: '#fff' }} readOnly />
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"/></svg>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09"/></svg>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><polyline points="21 3 14 10"/><polyline points="3 21 10 14"/></svg>
      </refractive.div>
    ),
  },
  {
    id: 'track-popover',
    label: 'Settings Popover',
    element: 'div',
    description: 'Audio/subtitle track picker popover',
    render: (props) => (
      <refractive.div style={{ width: 220, padding: '8px 0', background: 'rgba(30,30,30,0.85)', border: '1px solid rgba(255,255,255,0.1)', color: '#fff', fontSize: 13 }} refraction={props}>
        <div style={{ padding: '4px 12px', fontSize: 11, fontWeight: 600, opacity: 0.5, textTransform: 'uppercase', letterSpacing: '0.5px' }}>Audio</div>
        {['English (AAC Stereo)', 'Japanese (AC3 5.1)'].map((t, i) => (
          <div key={t} style={{ padding: '6px 12px', display: 'flex', gap: 8, cursor: 'pointer' }}>
            <span style={{ width: 16, textAlign: 'center' }}>{i === 0 ? '\u2713' : ''}</span>{t}
          </div>
        ))}
        <div style={{ padding: '4px 12px', fontSize: 11, fontWeight: 600, opacity: 0.5, textTransform: 'uppercase', letterSpacing: '0.5px', marginTop: 8 }}>Subtitles</div>
        {['Off', 'English \u2014 SRT', 'Japanese \u2014 ASS'].map((t, i) => (
          <div key={t} style={{ padding: '6px 12px', display: 'flex', gap: 8, cursor: 'pointer' }}>
            <span style={{ width: 16, textAlign: 'center' }}>{i === 0 ? '\u2713' : ''}</span>{t}
          </div>
        ))}
      </refractive.div>
    ),
  },
  {
    id: 'cta-card',
    label: 'CTA Card',
    element: 'div',
    description: 'Series call-to-action card (Resume/Up Next)',
    render: (props) => (
      <refractive.div style={{ width: 360, padding: 16, background: 'rgba(255,255,255,0.08)', border: '1px solid rgba(255,255,255,0.06)', color: '#fff' }} refraction={props}>
        <div style={{ fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '0.5px', opacity: 0.5, marginBottom: 8 }}>Up Next</div>
        <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 4 }}>S03E08 &mdash; "Lisa's Pony"</div>
        <div style={{ fontSize: 12, opacity: 0.6 }}>Homer takes out a loan to buy Lisa a pony.</div>
      </refractive.div>
    ),
  },
  {
    id: 'stat-chip',
    label: 'Stat Chip',
    element: 'div',
    description: 'Small series stat chip (Seasons/Episodes/etc.)',
    render: (props) => (
      <refractive.div style={{ display: 'inline-flex', flexDirection: 'column', alignItems: 'center', padding: '10px 18px', background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.06)', color: '#fff' }} refraction={props}>
        <span style={{ fontSize: 20, fontWeight: 700 }}>35</span>
        <span style={{ fontSize: 11, opacity: 0.5, textTransform: 'uppercase', letterSpacing: '0.5px' }}>Seasons</span>
      </refractive.div>
    ),
  },
  {
    id: 'nav-action',
    label: 'Nav Action',
    element: 'a',
    description: 'Navbar accent pill link (+ Add Series)',
    render: (props) => (
      <refractive.a style={{ display: 'inline-flex', alignItems: 'center', padding: '6px 18px', border: '1.5px solid #0A84FF', color: '#0A84FF', fontSize: 14, fontWeight: 600, cursor: 'pointer', textDecoration: 'none' }} refraction={props}>
        + Add Series
      </refractive.a>
    ),
  },
  {
    id: 'nav-btn',
    label: 'Nav Button',
    element: 'button',
    description: 'Navbar bordered pill button (Rescan/Refresh)',
    render: (props) => (
      <refractive.button style={{ display: 'inline-flex', alignItems: 'center', padding: '5px 14px', border: '1px solid rgba(255,255,255,0.12)', background: 'transparent', color: 'rgba(255,255,255,0.6)', fontSize: 13, fontWeight: 500, cursor: 'pointer', fontFamily: 'inherit' }} refraction={props}>
        Rescan
      </refractive.button>
    ),
  },
  {
    id: 'primary-btn',
    label: 'Primary Button',
    element: 'a',
    description: 'Large accent CTA pill (Add Your First Series)',
    render: (props) => (
      <refractive.a style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '12px 28px', background: '#0A84FF', color: '#fff', border: 'none', fontSize: 15, fontWeight: 600, cursor: 'pointer', textDecoration: 'none' }} refraction={props}>
        Add Your First Series
      </refractive.a>
    ),
  },
  {
    id: 'play-cta',
    label: 'Play CTA',
    element: 'button',
    description: 'Series play/resume CTA pill button',
    render: (props) => (
      <refractive.button style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '12px 28px', minWidth: 144, background: '#0A84FF', color: '#fff', border: 'none', fontSize: 15, fontWeight: 600, cursor: 'pointer' }} refraction={props}>
        <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg> Play
      </refractive.button>
    ),
  },
  {
    id: 'season-tab',
    label: 'Season Tab',
    element: 'button',
    description: 'Season selector pill tab (S1/S2/Specials)',
    render: (props) => (
      <refractive.button style={{ display: 'inline-flex', alignItems: 'center', padding: '7px 16px', border: '1.5px solid rgba(255,255,255,0.12)', background: 'transparent', color: 'rgba(255,255,255,0.6)', fontSize: 13, fontWeight: 500, cursor: 'pointer', whiteSpace: 'nowrap', fontFamily: 'inherit' }} refraction={props}>
        S1
      </refractive.button>
    ),
  },
]

// Param definitions — radius is specimen-only, the rest can be defaults
const PARAM_DEFS_ALL = [
  { key: 'radius', label: 'Radius', min: 0, max: 100, step: 1, defaultable: false },
  { key: 'blur', label: 'Blur', min: 0, max: 20, step: 0.5, defaultable: true },
  { key: 'bezelWidth', label: 'Bezel Width', min: 0, max: 30, step: 1, defaultable: true },
  { key: 'glassThickness', label: 'Glass Thickness', min: 0, max: 200, step: 5, defaultable: true },
  { key: 'specularOpacity', label: 'Specular Opacity', min: 0, max: 1, step: 0.05, defaultable: true },
  { key: 'refractiveIndex', label: 'Refractive Index', min: 1.0, max: 3.0, step: 0.05, defaultable: true },
]
const PARAM_DEFS_DEFAULTS = PARAM_DEFS_ALL.filter(p => p.defaultable)

const BACKGROUNDS = [
  { id: 'gradient-1', label: 'Warm Gradient', type: 'gradient', css: 'linear-gradient(135deg, #f97316 0%, #ec4899 50%, #8b5cf6 100%)' },
  { id: 'gradient-2', label: 'Ocean Gradient', type: 'gradient', css: 'linear-gradient(135deg, #06b6d4 0%, #3b82f6 50%, #6366f1 100%)' },
  { id: 'gradient-3', label: 'Forest Gradient', type: 'gradient', css: 'linear-gradient(135deg, #22c55e 0%, #14b8a6 50%, #0ea5e9 100%)' },
  { id: 'gradient-4', label: 'Dark Subtle', type: 'gradient', css: 'linear-gradient(135deg, #1e1e2e 0%, #2d1b4e 50%, #1a1a2e 100%)' },
  { id: 'gradient-5', label: 'Sunset', type: 'gradient', css: 'linear-gradient(135deg, #ff6b35 0%, #f7c948 25%, #ff6b9d 50%, #c44dff 75%, #6c5ce7 100%)' },
  { id: 'checkerboard', label: 'Checkerboard', type: 'checkerboard' },
  { id: 'noise', label: 'Color Noise', type: 'gradient', css: 'linear-gradient(45deg, #e74c3c 10%, #f1c40f 20%, #2ecc71 30%, #3498db 40%, #9b59b6 50%, #e74c3c 60%, #f1c40f 70%, #2ecc71 80%, #3498db 90%, #9b59b6 100%)' },
  { id: 'video', label: 'Video File...', type: 'video' },
]

function PreviewBackground({ bgId, videoSrc }) {
  const bg = BACKGROUNDS.find((b) => b.id === bgId)
  if (bgId === 'video' && videoSrc) {
    return <video src={videoSrc} autoPlay loop muted playsInline style={{ position: 'absolute', inset: 0, width: '100%', height: '100%', objectFit: 'cover' }} />
  }
  if (bg?.type === 'checkerboard') {
    return <div style={{ position: 'absolute', inset: 0, backgroundImage: 'repeating-conic-gradient(#808080 0% 25%, #404040 0% 50%)', backgroundSize: '40px 40px' }} />
  }
  return <div style={{ position: 'absolute', inset: 0, backgroundImage: bg?.css || 'none', backgroundColor: '#222' }} />
}

const S = {
  page: {
    position: 'fixed', inset: 0, display: 'flex', fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif', color: '#e0e0e0', fontSize: 13, zIndex: 9999, background: '#111',
  },
  sidebar: {
    width: 240, flexShrink: 0, background: 'rgba(30, 30, 30, 0.55)', backdropFilter: 'blur(40px) saturate(180%)', WebkitBackdropFilter: 'blur(40px) saturate(180%)', borderRight: '1px solid rgba(255,255,255,0.08)', display: 'flex', flexDirection: 'column', overflow: 'hidden',
  },
  sidebarTitlebar: {
    height: 52, flexShrink: 0, WebkitAppRegion: 'drag',
  },
  sidebarBackBtn: {
    display: 'flex', alignItems: 'center', gap: 6, padding: '0 14px', height: 32, fontSize: 13, fontWeight: 500, color: 'rgba(255,255,255,0.5)', background: 'none', border: 'none', cursor: 'pointer', WebkitAppRegion: 'no-drag', width: '100%', transition: 'color 0.15s',
  },
  sidebarSection: {
    padding: '10px 14px 6px', fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '1px', color: 'rgba(255,255,255,0.35)',
  },
  sidebarList: {
    flex: 1, overflowY: 'auto', padding: '0 8px 8px',
  },
  sidebarItem: (active) => ({
    padding: '7px 10px', cursor: 'pointer', fontSize: 13, background: active ? 'rgba(255,255,255,0.1)' : 'transparent', color: active ? '#fff' : 'rgba(255,255,255,0.55)', transition: 'all 0.15s', borderRadius: 6, marginBottom: 1,
  }),
  sidebarItemDesc: {
    fontSize: 11, color: 'rgba(255,255,255,0.3)', marginTop: 1,
  },
  main: {
    flex: 1, display: 'flex', flexDirection: 'column', overflow: 'hidden',
  },
  toolbar: {
    flexShrink: 0, padding: '10px 16px', background: '#1a1a1a', borderBottom: '1px solid #333', display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap',
  },
  toolbarLabel: {
    fontSize: 11, fontWeight: 600, color: '#888', textTransform: 'uppercase', letterSpacing: '0.5px',
  },
  bgBtn: (active) => ({
    padding: '4px 10px', fontSize: 11, background: active ? '#555' : '#2a2a2a', color: active ? '#fff' : '#aaa', border: '1px solid ' + (active ? '#777' : '#444'), cursor: 'pointer', transition: 'all 0.15s', borderRadius: 3,
  }),
  preview: {
    flex: 1, position: 'relative', overflow: 'hidden', display: 'flex', alignItems: 'center', justifyContent: 'center',
  },
  previewContent: {
    position: 'relative', zIndex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, padding: 24,
  },
  controls: {
    flexShrink: 0, padding: '12px 16px', background: '#1a1a1a', borderTop: '1px solid #333', display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 260, overflowY: 'auto',
  },
  controlRow: {
    display: 'flex', alignItems: 'center', gap: 8,
  },
  controlLabel: (inherited) => ({
    width: 130, fontSize: 12, color: inherited ? '#666' : '#aaa', flexShrink: 0, fontStyle: inherited ? 'italic' : 'normal',
  }),
  controlSlider: {
    flex: 1, height: 4, accentColor: '#888',
  },
  controlValue: {
    width: 50, fontSize: 12, color: '#fff', textAlign: 'right', fontVariantNumeric: 'tabular-nums',
  },
  surfaceRow: {
    display: 'flex', alignItems: 'center', gap: 8, marginTop: 2,
  },
  surfaceBtn: (active) => ({
    padding: '3px 10px', fontSize: 11, background: active ? '#555' : '#2a2a2a', color: active ? '#fff' : '#aaa', border: '1px solid ' + (active ? '#777' : '#444'), cursor: 'pointer', borderRadius: 3,
  }),
  resetBtn: {
    padding: '4px 12px', fontSize: 11, background: '#333', color: '#ccc', border: '1px solid #555', cursor: 'pointer', marginLeft: 'auto', borderRadius: 3,
  },
  codeBlock: {
    padding: '8px 12px', background: '#111', border: '1px solid #333', fontSize: 11, color: '#aaa', fontFamily: 'SF Mono, Menlo, Consolas, monospace', overflowX: 'auto', whiteSpace: 'pre', marginTop: 4, borderRadius: 4, cursor: 'pointer',
  },
  overrideBtn: {
    padding: '1px 6px', fontSize: 10, background: 'none', border: '1px solid #555', color: '#888', cursor: 'pointer', borderRadius: 3, flexShrink: 0,
  },
}

export default function Playground() {
  const navigate = useNavigate()

  // 'defaults' or a specimen id
  const [mode, setMode] = useState(SPECIMENS[0].id)
  const isDefaultsMode = mode === 'defaults'

  // Which specimen to preview when editing defaults
  const [defaultsPreviewId, setDefaultsPreviewId] = useState(SPECIMENS[0].id)

  // --- State: base defaults (shared values, no radius) ---
  const [committedBase, setCommittedBase] = useState(() => ({ ...GLASS_BASE }))
  const [draftBase, setDraftBase] = useState(() => ({ ...GLASS_BASE }))

  // --- State: per-specimen overrides (only keys the user explicitly set) ---
  // Each entry is a partial object: { radius: N, ...only overridden keys }
  const [committedOverrides, setCommittedOverrides] = useState(() => {
    const init = {}
    for (const s of SPECIMENS) {
      // Start with what glass.json had as resolved, then strip keys that match base defaults
      const resolved = GLASS_RESOLVED[s.id] || {}
      const overrides = { radius: resolved.radius }
      for (const key of ['blur', 'bezelWidth', 'glassThickness', 'specularOpacity', 'refractiveIndex', 'bezelHeightFn']) {
        if (resolved[key] !== GLASS_BASE[key]) {
          overrides[key] = resolved[key]
        }
      }
      init[s.id] = overrides
    }
    return init
  })
  const [draftOverrides, setDraftOverrides] = useState(() => {
    const init = {}
    for (const s of SPECIMENS) {
      const resolved = GLASS_RESOLVED[s.id] || {}
      const overrides = { radius: resolved.radius }
      for (const key of ['blur', 'bezelWidth', 'glassThickness', 'specularOpacity', 'refractiveIndex', 'bezelHeightFn']) {
        if (resolved[key] !== GLASS_BASE[key]) {
          overrides[key] = resolved[key]
        }
      }
      init[s.id] = overrides
    }
    return init
  })

  const [dragging, setDragging] = useState(false)
  const [bgId, setBgId] = useState('gradient-1')
  const [zoom, setZoom] = useState(1)
  const [videoSrc, setVideoSrc] = useState(null)
  const [saveStatus, setSaveStatus] = useState(null)
  const videoInputRef = useRef(null)

  // --- Helpers to resolve effective values ---
  // Effective params for a specimen = base defaults + specimen overrides
  const resolveSpecimen = useCallback((base, overrides) => ({
    ...base,
    ...overrides,
  }), [])

  // Current specimen being previewed
  const previewId = isDefaultsMode ? defaultsPreviewId : mode
  const specimen = SPECIMENS.find(s => s.id === previewId)

  // --- Draft/committed values for current editing context ---
  // In defaults mode: sliders edit draftBase directly, preview uses merged values
  // In specimen mode: sliders edit the resolved (merged) values
  const currentDraft = isDefaultsMode
    ? draftBase
    : resolveSpecimen(draftBase, draftOverrides[mode] || {})

  const currentCommitted = isDefaultsMode
    ? committedBase
    : resolveSpecimen(committedBase, committedOverrides[mode] || {})

  // Merged values for the preview rendering
  // In defaults mode: base values + only the specimen's radius (so you see defaults changes)
  // In specimen mode: full merge with all overrides
  const previewCommitted = isDefaultsMode
    ? { ...committedBase, radius: (committedOverrides[previewId] || {}).radius || 0 }
    : resolveSpecimen(committedBase, committedOverrides[previewId] || {})

  // Which keys are overridden for current specimen
  const currentOverrideKeys = isDefaultsMode
    ? new Set(Object.keys(draftOverrides[previewId] || {}).filter(k => k !== 'radius'))
    : new Set(Object.keys(draftOverrides[mode] || {}).filter(k => k !== 'radius'))

  // --- Slider handlers ---
  const setDraftParam = useCallback((key, value) => {
    if (isDefaultsMode) {
      // Editing defaults: update base
      setDraftBase(prev => ({ ...prev, [key]: value }))
    } else {
      // Editing specimen: add/update override
      setDraftOverrides(prev => ({
        ...prev,
        [mode]: { ...prev[mode], [key]: value },
      }))
    }
  }, [isDefaultsMode, mode])

  const commitParams = useCallback(() => {
    if (isDefaultsMode) {
      setCommittedBase({ ...draftBase })
    } else {
      setCommittedOverrides(prev => ({
        ...prev,
        [mode]: { ...draftOverrides[mode] },
      }))
    }
    setDragging(false)
  }, [isDefaultsMode, mode, draftBase, draftOverrides])

  const resetParams = useCallback(() => {
    if (isDefaultsMode) {
      setDraftBase({ ...GLASS_BASE })
      setCommittedBase({ ...GLASS_BASE })
    } else {
      // Reset specimen to only radius (inherit everything from defaults)
      const resolved = GLASS_RESOLVED[mode] || {}
      const overrides = { radius: resolved.radius }
      for (const key of ['blur', 'bezelWidth', 'glassThickness', 'specularOpacity', 'refractiveIndex', 'bezelHeightFn']) {
        if (resolved[key] !== GLASS_BASE[key]) {
          overrides[key] = resolved[key]
        }
      }
      setDraftOverrides(prev => ({ ...prev, [mode]: overrides }))
      setCommittedOverrides(prev => ({ ...prev, [mode]: overrides }))
    }
  }, [isDefaultsMode, mode])

  const setSurfaceFn = useCallback((fn) => {
    if (isDefaultsMode) {
      setDraftBase(prev => ({ ...prev, bezelHeightFn: fn }))
      setCommittedBase(prev => ({ ...prev, bezelHeightFn: fn }))
    } else {
      setDraftOverrides(prev => ({ ...prev, [mode]: { ...prev[mode], bezelHeightFn: fn } }))
      setCommittedOverrides(prev => ({ ...prev, [mode]: { ...prev[mode], bezelHeightFn: fn } }))
    }
  }, [isDefaultsMode, mode])

  // Remove an override so specimen inherits from defaults again
  const clearOverride = useCallback((key) => {
    setDraftOverrides(prev => {
      const copy = { ...prev[mode] }
      delete copy[key]
      return { ...prev, [mode]: copy }
    })
    setCommittedOverrides(prev => {
      const copy = { ...prev[mode] }
      delete copy[key]
      return { ...prev, [mode]: copy }
    })
  }, [mode])

  // --- Save to glass.json ---
  const handleSave = useCallback(async () => {
    setSaveStatus('saving')
    try {
      const config = { defaults: { ...committedBase } }
      for (const s of SPECIMENS) {
        config[s.id] = { ...(committedOverrides[s.id] || { radius: GLASS_RESOLVED[s.id]?.radius || 0 }) }
      }
      await window.api.saveGlassConfig(config)
      setSaveStatus('saved')
      setTimeout(() => setSaveStatus(null), 2000)
    } catch (err) {
      console.error('Failed to save glass config:', err)
      setSaveStatus('error')
      setTimeout(() => setSaveStatus(null), 3000)
    }
  }, [committedBase, committedOverrides])

  // Build refraction prop — always from the preview-resolved values
  const previewValues = isDefaultsMode ? previewCommitted : currentCommitted
  const refractionProp = {
    radius: previewValues.radius,
    blur: previewValues.blur,
    bezelWidth: previewValues.bezelWidth,
    glassThickness: previewValues.glassThickness,
    specularOpacity: previewValues.specularOpacity,
    refractiveIndex: previewValues.refractiveIndex,
    bezelHeightFn: SURFACE_FNS[previewValues.bezelHeightFn],
  }

  const handleBgClick = (b) => {
    if (b.id === 'video') {
      videoInputRef.current?.click()
    } else {
      setBgId(b.id)
      setVideoSrc(null)
    }
  }

  const handleVideoFile = (e) => {
    const file = e.target.files?.[0]
    if (file) {
      setVideoSrc(URL.createObjectURL(file))
      setBgId('video')
    }
  }

  // Code snippet
  const codeSnippet = isDefaultsMode
    ? `// defaults\n{ blur: ${currentDraft.blur}, bezelWidth: ${currentDraft.bezelWidth}, glassThickness: ${currentDraft.glassThickness}, specularOpacity: ${currentDraft.specularOpacity}, refractiveIndex: ${currentDraft.refractiveIndex}${currentDraft.bezelHeightFn !== 'convex' ? `, bezelHeightFn: "${currentDraft.bezelHeightFn}"` : ''} }`
    : `refraction={{ radius: ${currentDraft.radius}, blur: ${currentDraft.blur}, bezelWidth: ${currentDraft.bezelWidth}, glassThickness: ${currentDraft.glassThickness}, specularOpacity: ${currentDraft.specularOpacity}, refractiveIndex: ${currentDraft.refractiveIndex}${currentDraft.bezelHeightFn !== 'convex' ? `, bezelHeightFn: ${currentDraft.bezelHeightFn}` : ''} }}`

  // Global mouseup listener to commit slider changes
  useEffect(() => {
    if (!dragging) return
    const handleUp = () => commitParams()
    window.addEventListener('mouseup', handleUp)
    window.addEventListener('pointerup', handleUp)
    return () => {
      window.removeEventListener('mouseup', handleUp)
      window.removeEventListener('pointerup', handleUp)
    }
  }, [dragging, commitParams])

  // Which param defs to show
  const paramDefs = isDefaultsMode ? PARAM_DEFS_DEFAULTS : PARAM_DEFS_ALL

  return (
    <div style={S.page}>
      {/* Sidebar */}
      <div style={S.sidebar}>
        <div style={S.sidebarTitlebar} />

        <button
          style={S.sidebarBackBtn}
          onClick={() => navigate('/')}
          onMouseEnter={(e) => { e.currentTarget.style.color = 'rgba(255,255,255,0.85)' }}
          onMouseLeave={(e) => { e.currentTarget.style.color = 'rgba(255,255,255,0.5)' }}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="15 18 9 12 15 6"/></svg>
          Back to App
        </button>

        <div style={S.sidebarList}>
          {/* Defaults entry */}
          <div style={S.sidebarSection}>Defaults</div>
          <div style={S.sidebarItem(isDefaultsMode)} onClick={() => setMode('defaults')}>
            <div>Base Values</div>
            <div style={S.sidebarItemDesc}>inherited by all</div>
          </div>

          {/* Specimen list */}
          <div style={{ ...S.sidebarSection, marginTop: 8 }}>Specimens</div>
          {SPECIMENS.map((s) => (
            <div key={s.id} style={S.sidebarItem(!isDefaultsMode && s.id === mode)} onClick={() => setMode(s.id)}>
              <div>{s.label}</div>
              <div style={S.sidebarItemDesc}>{s.element}</div>
            </div>
          ))}
        </div>
      </div>

      {/* Main area */}
      <div style={S.main}>
        {/* Background selector toolbar */}
        <div style={S.toolbar}>
          <span style={S.toolbarLabel}>Background</span>
          {BACKGROUNDS.map((b) => (
            <button key={b.id} style={S.bgBtn(b.id === bgId)} onClick={() => handleBgClick(b)}>
              {b.label}
            </button>
          ))}
          <input ref={videoInputRef} type="file" accept="video/*" style={{ display: 'none' }} onChange={handleVideoFile} />
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 6 }}>
            <span style={S.toolbarLabel}>Zoom</span>
            <button style={{ ...S.bgBtn(false), visibility: zoom !== 1 ? 'visible' : 'hidden' }} onClick={() => setZoom(1)}>1:1</button>
            <button style={S.bgBtn(false)} onClick={() => setZoom(z => Math.max(0.25, +(z - 0.25).toFixed(2)))}>-</button>
            <span style={{ fontSize: 11, color: '#ccc', width: 40, textAlign: 'center', fontVariantNumeric: 'tabular-nums' }}>{Math.round(zoom * 100)}%</span>
            <button style={S.bgBtn(false)} onClick={() => setZoom(z => Math.min(5, +(z + 0.25).toFixed(2)))}>+</button>
          </div>
        </div>

        {/* Preview area */}
        <div style={S.preview} onWheel={(e) => {
          e.preventDefault()
          setZoom(z => {
            const delta = e.deltaY > 0 ? -0.1 : 0.1
            return Math.min(5, Math.max(0.25, +(z + delta).toFixed(2)))
          })
        }}>
          <PreviewBackground bgId={bgId} videoSrc={videoSrc} />
          <div style={{ ...S.previewContent, transform: `scale(${zoom})` }}>
            {specimen.render(refractionProp)}
          </div>
        </div>

        {/* Controls panel */}
        <div style={S.controls}>
          <div style={{ display: 'flex', alignItems: 'center', marginBottom: 4, gap: 8 }}>
            {isDefaultsMode ? (
              <>
                <span style={{ fontSize: 12, fontWeight: 600, color: '#fff' }}>Defaults</span>
                <span style={{ fontSize: 11, color: '#666' }}>shared base values for all specimens</span>
                {/* Preview picker */}
                <span style={{ fontSize: 11, color: '#888', marginLeft: 'auto' }}>Preview on</span>
                <select
                  value={defaultsPreviewId}
                  onChange={(e) => setDefaultsPreviewId(e.target.value)}
                  style={{ fontSize: 11, background: '#2a2a2a', color: '#ccc', border: '1px solid #555', borderRadius: 3, padding: '2px 6px', cursor: 'pointer' }}
                >
                  {SPECIMENS.map(s => (
                    <option key={s.id} value={s.id}>{s.label}</option>
                  ))}
                </select>
              </>
            ) : (
              <>
                <span style={{ fontSize: 12, fontWeight: 600, color: '#fff' }}>{specimen.label}</span>
                <span style={{ fontSize: 11, color: '#666' }}>{specimen.description}</span>
              </>
            )}
            <button style={{ ...S.resetBtn, ...(isDefaultsMode ? {} : { marginLeft: 'auto' }) }} onClick={resetParams}>Reset</button>
            <button
              style={{ ...S.resetBtn, marginLeft: isDefaultsMode ? 0 : undefined, background: saveStatus === 'saved' ? '#2a5a2a' : saveStatus === 'error' ? '#5a2a2a' : '#2a3a5a', color: saveStatus === 'saved' ? '#6ee76e' : saveStatus === 'error' ? '#e76e6e' : '#8ab4f8', border: '1px solid ' + (saveStatus === 'saved' ? '#4a8a4a' : saveStatus === 'error' ? '#8a4a4a' : '#4a6a9a') }}
              onClick={handleSave}
              disabled={saveStatus === 'saving'}
            >
              {saveStatus === 'saving' ? 'Saving...' : saveStatus === 'saved' ? 'Saved' : saveStatus === 'error' ? 'Error' : 'Save to Config'}
            </button>
          </div>

          {paramDefs.map((p) => {
            const inherited = !isDefaultsMode && p.defaultable && !currentOverrideKeys.has(p.key)
            return (
              <div key={p.key} style={S.controlRow}>
                <span style={S.controlLabel(inherited)}>
                  {p.label}
                  {inherited && <span style={{ fontSize: 9, marginLeft: 4 }}>(default)</span>}
                </span>
                <input
                  type="range"
                  min={p.min}
                  max={p.max}
                  step={p.step}
                  value={currentDraft[p.key]}
                  onPointerDown={() => setDragging(true)}
                  onInput={(e) => setDraftParam(p.key, parseFloat(e.target.value))}
                  style={{ ...S.controlSlider, opacity: inherited ? 0.4 : 1 }}
                />
                <span style={S.controlValue}>{currentDraft[p.key]}</span>
                {/* Show clear-override button for specimen mode when key is overridden */}
                {!isDefaultsMode && p.defaultable && currentOverrideKeys.has(p.key) && (
                  <button style={S.overrideBtn} onClick={() => clearOverride(p.key)} title="Remove override, inherit from defaults">
                    inherit
                  </button>
                )}
              </div>
            )
          })}

          {/* Surface function selector */}
          <div style={S.surfaceRow}>
            <span style={S.controlLabel(!isDefaultsMode && !currentOverrideKeys.has('bezelHeightFn'))}>
              Surface Function
              {!isDefaultsMode && !currentOverrideKeys.has('bezelHeightFn') && <span style={{ fontSize: 9, marginLeft: 4 }}>(default)</span>}
            </span>
            {Object.keys(SURFACE_FNS).map((fn) => (
              <button key={fn} style={S.surfaceBtn(currentDraft.bezelHeightFn === fn)} onClick={() => setSurfaceFn(fn)}>
                {fn}
              </button>
            ))}
            {!isDefaultsMode && currentOverrideKeys.has('bezelHeightFn') && (
              <button style={S.overrideBtn} onClick={() => clearOverride('bezelHeightFn')} title="Remove override, inherit from defaults">
                inherit
              </button>
            )}
          </div>

          {/* Code snippet — click to copy */}
          <div style={S.codeBlock} onClick={() => navigator.clipboard?.writeText(codeSnippet)} title="Click to copy">
            {codeSnippet}
          </div>
          {dragging && <div style={{ fontSize: 10, color: '#666', textAlign: 'center' }}>Release to apply...</div>}
        </div>
      </div>
    </div>
  )
}
