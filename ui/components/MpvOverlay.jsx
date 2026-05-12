// Desktop player UI when libmpv is the engine. Renders the same controls
// the web/HLS WebVideoPlayer renders — refractive glass close button, skip
// circles, play/pause, utility pill (volume + settings + fullscreen), and
// the track popover for audio/subtitle selection. Only difference: there's
// no <video> element. libmpv draws into the BrowserWindow's NSView behind
// Chromium; this component is the React overlay on top.
//
// Track stream identifier: embed engine tracks come back with `id`, HLS uses
// `index`. We use `s.id ?? s.index` so the same JSX works either way.

import { useEffect, useRef, useState, useCallback } from 'react'
import { createPortal } from 'react-dom'
import { refractive } from '../config/refractive'
import { usePlayer } from '../context/PlayerContext'
import { useApi } from '../context/ApiContext'
import { useGlassConfig } from '../config/useGlassConfig'
import { formatTime } from '../utils'

// Mirrors VideoPlayer.jsx so labels and presets stay in sync.
const LANG_NAMES = {
  eng: 'English', en: 'English',
  ukr: 'Ukrainian', uk: 'Ukrainian',
  rus: 'Russian', ru: 'Russian',
  jpn: 'Japanese', ja: 'Japanese',
  fre: 'French', fr: 'French',
  ger: 'German', de: 'German',
  spa: 'Spanish', es: 'Spanish',
  ita: 'Italian', it: 'Italian',
  por: 'Portuguese', pt: 'Portuguese',
  chi: 'Chinese', zh: 'Chinese',
  kor: 'Korean', ko: 'Korean',
  ara: 'Arabic', ar: 'Arabic',
  hin: 'Hindi', hi: 'Hindi',
  pol: 'Polish', pl: 'Polish',
  tur: 'Turkish', tr: 'Turkish',
  nld: 'Dutch', nl: 'Dutch',
  swe: 'Swedish', sv: 'Swedish',
  nor: 'Norwegian', no: 'Norwegian',
  dan: 'Danish', da: 'Danish',
  fin: 'Finnish', fi: 'Finnish',
  cze: 'Czech', cs: 'Czech',
  hun: 'Hungarian', hu: 'Hungarian',
  ron: 'Romanian', ro: 'Romanian',
  bul: 'Bulgarian', bg: 'Bulgarian',
  hrv: 'Croatian', hr: 'Croatian',
  srp: 'Serbian', sr: 'Serbian',
  slv: 'Slovenian', sl: 'Slovenian',
  und: 'Unknown',
}

function langName(code) {
  if (!code) return 'Unknown'
  const k = String(code).toLowerCase()
  return LANG_NAMES[k] || code
}

function audioLabel(stream) {
  const lang = langName(stream.language)
  const ch = stream.channels === 6 ? '5.1' : stream.channels === 8 ? '7.1' : stream.channels === 2 ? 'Stereo' : stream.channels === 1 ? 'Mono' : (stream.channels ? `${stream.channels}ch` : null)
  const codec = (stream.codec || '').toUpperCase()
  return [lang, codec, ch].filter(Boolean).join(' • ') || (stream.title || 'Audio')
}

function subtitleLabel(stream) {
  const lang = langName(stream.language)
  const info = stream.title || (stream.codec || '').toUpperCase()
  return info && info !== lang ? `${lang} — ${info}` : lang
}

const SUB_SIZES = [
  { id: 'small',  label: 'S' },
  { id: 'medium', label: 'M' },
  { id: 'large',  label: 'L' },
]

const SUB_STYLES = [
  { id: 'classic',     label: 'Classic' },
  { id: 'outline',     label: 'Outline' },
  { id: 'drop-shadow', label: 'Drop Shadow' },
  { id: 'transparent', label: 'Transparent' },
]

const CONTROLS_TIMEOUT_MS = 3000

// Mirrors WebVideoPlayer's DevPlaybackInfo so dev builds get the same
// strategy / codec / resolution / bitrate badge in the corner.
function DevPlaybackInfo({ strategy, video, bitrate, audioStream }) {
  if (!import.meta.env.DEV) return null

  const STRATEGY_COLOR = {
    direct_play:     '#34c759',
    direct_stream:   '#34c759',
    audio_transcode: '#ffd60a',
    full_transcode:  '#ff453a',
  }
  const HDR_TRANSFERS = new Set(['smpte2084', 'arib-std-b67'])
  const isHdr = !!video?.color_transfer && HDR_TRANSFERS.has(video.color_transfer)
  const mbps = bitrate ? `${(bitrate / 1_000_000).toFixed(1)} Mbps` : null
  const res = video?.width && video?.height ? `${video.width}×${video.height}` : null
  const bitDepth = video?.pix_fmt?.match(/p10|p12|p16/) ? '10-bit' : '8-bit'

  const row = { display: 'flex', gap: 6, alignItems: 'baseline' }
  const dim = { color: '#888', fontWeight: 400 }

  return (
    <div style={{
      // top: 56 clears Electron's traffic-light buttons (positioned at y:16
      // with hiddenInset titleBar) so the badge isn't covered.
      position: 'absolute', top: 56, left: 12, zIndex: 9999,
      pointerEvents: 'none', userSelect: 'text',
      background: 'rgba(0,0,0,0.78)', backdropFilter: 'blur(8px)',
      color: '#fff', fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 11, lineHeight: 1.4, padding: '6px 10px', borderRadius: 6,
      border: '1px solid rgba(255,255,255,0.1)',
      maxWidth: 320, fontWeight: 500,
    }}>
      <div style={row}>
        <span style={{
          background: STRATEGY_COLOR[strategy] || '#666', color: '#000',
          padding: '1px 5px', borderRadius: 3, fontSize: 10, fontWeight: 700,
          letterSpacing: 0.3,
        }}>
          {strategy ? strategy.toUpperCase().replace('_', ' ') : '—'}
        </span>
        {isHdr && (
          <span style={{
            background: '#af52de', color: '#fff',
            padding: '1px 5px', borderRadius: 3, fontSize: 10, fontWeight: 700,
            letterSpacing: 0.3,
          }}>HDR</span>
        )}
      </div>
      {video && (
        <div style={{ marginTop: 4 }}>
          <span style={dim}>video </span>
          {(video.codec || '?').toUpperCase()} {res} {bitDepth}
        </div>
      )}
      {video?.color_transfer && (
        <div><span style={dim}>transfer </span>{video.color_transfer}</div>
      )}
      {mbps && (
        <div><span style={dim}>source </span>{mbps}</div>
      )}
      {audioStream && (
        <div>
          <span style={dim}>audio </span>
          {(audioStream.codec || '?').toUpperCase()}
          {audioStream.channels ? ` ${audioStream.channels}ch` : ''}
          {audioStream.language && audioStream.language !== 'und' ? ` ${audioStream.language}` : ''}
        </div>
      )}
    </div>
  )
}

export default function MpvOverlay() {
  const { playerState, closePlayer, seekPlayback, switchAudio, switchSubtitle } = usePlayer()
  const api = useApi()

  const closeBtnGlass = useGlassConfig('close-btn')
  const skipBtnGlass = useGlassConfig('skip-btn')
  const playBtnGlass = useGlassConfig('play-btn')
  const utilityPillGlass = useGlassConfig('utility-pill')
  const trackPopoverGlass = useGlassConfig('track-popover')

  const [controlsVisible, setControlsVisible] = useState(true)
  const [trackMenuOpen, setTrackMenuOpen] = useState(false)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [volume, setVolume] = useState(1)
  const idleTimerRef = useRef(null)
  const trackMenuRef = useRef(null)
  const lastReportRef = useRef(0)

  const time = playerState.currentTime || 0
  const duration = playerState.duration || 0
  const paused = !!playerState.paused
  // engineReady comes from PlayerContext: true once libvlc has emitted at
  // least one state push past the requested startTime. Until then we show
  // a black curtain + spinner so the user doesn't see the transparent
  // window through Chromium during libvlc's decoder warmup.
  const videoReady = !!playerState.engineReady
  const subtitleSize = playerState.subtitleSize || 'medium'
  const subtitleStyle = playerState.subtitleStyle || 'classic'

  const showControls = useCallback(() => {
    setControlsVisible(true)
    if (idleTimerRef.current) clearTimeout(idleTimerRef.current)
    idleTimerRef.current = setTimeout(() => {
      if (!trackMenuOpen) setControlsVisible(false)
    }, CONTROLS_TIMEOUT_MS)
  }, [trackMenuOpen])

  useEffect(() => {
    showControls()
    return () => { if (idleTimerRef.current) clearTimeout(idleTimerRef.current) }
  }, [showControls])

  // While the player is open, make the rest of the React app see-through
  // so libvlc's NSView (rendering behind Chromium) is visible. The overlay
  // itself is portaled into <body> so it stays composited.
  // Transparency CSS lives in app.css (body.engine-playing) and is toggled
  // synchronously by PlayerContext.openPlayer / closePlayer, so the
  // see-through transition happens on the same frame as the click.

  // Periodic progress report so resume-on-reopen works. Skip while
  // duration is unknown — server rejects (422) report_progress with
  // duration<=0, and mpv may not have propagated FILE_LOADED yet on the
  // first few ticks.
  useEffect(() => {
    const t = setInterval(() => {
      if (paused) return
      if (duration <= 0) return
      if (Math.abs(time - lastReportRef.current) < 1) return
      lastReportRef.current = time
      api.reportProgress?.(time, duration, {
        episodeId: playerState.episodeId,
        movieId: playerState.movieId,
      })
    }, 3000)
    return () => clearInterval(t)
  }, [api, time, duration, paused, playerState.episodeId, playerState.movieId])

  const togglePlay = useCallback(() => {
    if (paused) api.resumePlayback?.()
    else api.pausePlayback?.()
  }, [api, paused])

  const handleClose = useCallback(() => {
    closePlayer(time, duration)
  }, [closePlayer, time, duration])

  const handleSeekRelative = useCallback((delta) => {
    const next = Math.max(0, Math.min(duration || 0, time + delta))
    seekPlayback(next)
  }, [seekPlayback, time, duration])

  const handleSeekBarInput = useCallback((e) => {
    const v = Number(e.target.value)
    seekPlayback(v)
  }, [seekPlayback])

  const toggleFullscreen = useCallback(() => {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen?.()
      setIsFullscreen(true)
    } else {
      document.exitFullscreen?.()
      setIsFullscreen(false)
    }
  }, [])

  const handleVolumeChange = useCallback((e) => {
    const v = Number(e.target.value)
    setVolume(v)
    // embed engine volume isn't wired to the native module yet; stub here so the
    // slider's UI still tracks. Setting api volume can be added later via
    // a vlcSetVolume binding.
  }, [])

  const setSubtitleAppearance = useCallback((opts) => {
    api.setSubtitleAppearance?.(opts)
  }, [api])

  // Close popover when clicking outside.
  useEffect(() => {
    if (!trackMenuOpen) return
    const onClick = (e) => {
      if (trackMenuRef.current && !trackMenuRef.current.contains(e.target)) {
        setTrackMenuOpen(false)
      }
    }
    document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [trackMenuOpen])

  // Keyboard shortcuts.
  useEffect(() => {
    const onKey = (e) => {
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return
      if (e.key === ' ') { e.preventDefault(); togglePlay() }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); handleSeekRelative(-10) }
      else if (e.key === 'ArrowRight') { e.preventDefault(); handleSeekRelative(10) }
      else if (e.key === 'Escape') { handleClose() }
      else if (e.key === 'f' || e.key === 'F') { toggleFullscreen() }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [togglePlay, handleSeekRelative, handleClose, toggleFullscreen])

  if (!playerState.open) return null

  const totalDuration = duration || 1
  const progressPct = duration > 0 ? (time / duration) * 100 : 0

  const activeAudio = playerState.audioStreams?.find(s => (s.id ?? s.index) === playerState.activeAudioIndex)

  return createPortal(
    <div
      className={`video-player-overlay${controlsVisible ? ' controls-visible' : ''}`}
      style={{ background: 'transparent' }}
      onMouseMove={showControls}
      onClick={(e) => {
        if (e.target === e.currentTarget) {
          if (trackMenuOpen) setTrackMenuOpen(false)
          else togglePlay()
        }
      }}
      onWheel={(e) => e.stopPropagation()}
    >
      <DevPlaybackInfo
        strategy={playerState.strategy}
        video={playerState.video}
        bitrate={playerState.bitrate}
        audioStream={activeAudio}
      />

      {/* Loading curtain is provided by the body.engine-playing CSS pseudo-
       * element so it exists from the same frame the click was handled —
       * no React-render lag visible as a transparent flash. */}

      {/* Top-right: close button */}
      <div
        className={`video-player-top${controlsVisible ? ' visible' : ''}`}
        onClick={(e) => e.stopPropagation()}
      >
        <refractive.button className="video-player-close" tabIndex={0} onClick={(e) => { e.stopPropagation(); handleClose() }} refraction={closeBtnGlass}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </refractive.button>
      </div>

      {/* Center: skip back, play/pause, skip forward */}
      <div
        className={`video-player-center${controlsVisible ? ' visible' : ''}`}
        onClick={(e) => e.stopPropagation()}
      >
        <refractive.button className="video-player-skip-btn" tabIndex={0} onClick={() => handleSeekRelative(-10)} refraction={skipBtnGlass}>
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>
          </svg>
          <span className="video-player-skip-num">10</span>
        </refractive.button>

        <refractive.button
          className="video-player-play-btn"
          tabIndex={0}
          onClick={togglePlay}
          refraction={playBtnGlass}
        >
          {paused ? (
            <svg width="36" height="36" viewBox="0 0 24 24" fill="currentColor"><polygon points="6 3 20 12 6 21"/></svg>
          ) : (
            <svg width="36" height="36" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="3" width="5" height="18" rx="1"/><rect x="14" y="3" width="5" height="18" rx="1"/></svg>
          )}
        </refractive.button>

        <refractive.button className="video-player-skip-btn" tabIndex={0} onClick={() => handleSeekRelative(30)} refraction={skipBtnGlass}>
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.13-9.36L23 10"/>
          </svg>
          <span className="video-player-skip-num">10</span>
        </refractive.button>
      </div>

      {/* Bottom: title + utilities + seek */}
      <div
        className={`video-player-bottom${controlsVisible ? ' visible' : ''}`}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="video-player-bottom-info">
          <span className="video-player-bottom-title">{playerState.title}</span>
          {playerState.subtitle && (
            <span className="video-player-bottom-subtitle">{playerState.subtitle}</span>
          )}
        </div>

        <div className="video-player-track-menu-anchor" ref={trackMenuRef}>
          <refractive.div className="video-player-utilities" refraction={utilityPillGlass}>
            <input
              type="range"
              className="video-player-volume-slider"
              tabIndex={0}
              min={0}
              max={1}
              step={0.05}
              value={volume}
              onChange={handleVolumeChange}
              style={{ background: `linear-gradient(to right, #fff 0%, #fff ${volume * 100}%, rgba(255,255,255,.3) ${volume * 100}%, rgba(255,255,255,.3) 100%)` }}
            />
            <button className="video-player-util-icon video-player-volume-btn" tabIndex={0} onClick={() => {
              setVolume(volume === 0 ? 1 : 0)
            }}>
              {volume === 0 ? (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><line x1="23" y1="9" x2="17" y2="15"/><line x1="17" y1="9" x2="23" y2="15"/>
                </svg>
              ) : (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"/>
                </svg>
              )}
            </button>
            <button
              className={`video-player-util-icon${trackMenuOpen ? ' active' : ''}`}
              tabIndex={0}
              onClick={() => setTrackMenuOpen(v => !v)}
              title="Audio & Subtitles"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
              </svg>
            </button>
            <button className="video-player-util-icon" tabIndex={0} onClick={toggleFullscreen}>
              {isFullscreen ? (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M8 3v3a2 2 0 0 1-2 2H3m18 0h-3a2 2 0 0 1-2-2V3m0 18v-3a2 2 0 0 1 2-2h3M3 16h3a2 2 0 0 1 2 2v3"/>
                </svg>
              ) : (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><polyline points="21 3 14 10"/><polyline points="3 21 10 14"/>
                </svg>
              )}
            </button>
          </refractive.div>

          {trackMenuOpen && (
            <refractive.div className="video-player-track-popover" refraction={trackPopoverGlass}>
              {playerState.audioStreams?.length > 1 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Audio</div>
                  {playerState.audioStreams.map((s, idx) => {
                    const sid = s.id ?? s.index
                    const active = sid === playerState.activeAudioIndex
                    return (
                      <button
                        key={sid}
                        tabIndex={0}
                        autoFocus={idx === 0}
                        className={`track-popover-item${active ? ' active' : ''}`}
                        onClick={() => {
                          if (!active) switchAudio(sid)
                          setTrackMenuOpen(false)
                        }}
                      >
                        <span className="track-popover-check">{active ? '✓' : ''}</span>
                        <span className="track-popover-label">{audioLabel(s)}</span>
                      </button>
                    )
                  })}
                </div>
              )}

              {playerState.subtitleStreams?.length > 0 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Subtitles</div>
                  <button
                    tabIndex={0}
                    autoFocus={!(playerState.audioStreams?.length > 1)}
                    className={`track-popover-item${playerState.activeSubtitleIndex == null ? ' active' : ''}`}
                    onClick={() => {
                      if (playerState.activeSubtitleIndex != null) switchSubtitle(null)
                      setTrackMenuOpen(false)
                    }}
                  >
                    <span className="track-popover-check">
                      {playerState.activeSubtitleIndex == null ? '✓' : ''}
                    </span>
                    <span className="track-popover-label">Off</span>
                  </button>
                  {playerState.subtitleStreams.map((s) => {
                    const sid = s.id ?? s.index
                    const active = sid === playerState.activeSubtitleIndex
                    return (
                      <button
                        key={sid}
                        tabIndex={0}
                        className={`track-popover-item${active ? ' active' : ''}`}
                        onClick={() => {
                          if (!active) switchSubtitle(sid)
                          setTrackMenuOpen(false)
                        }}
                      >
                        <span className="track-popover-check">{active ? '✓' : ''}</span>
                        <span className="track-popover-label">{subtitleLabel(s)}</span>
                      </button>
                    )
                  })}
                </div>
              )}

              <div className="track-popover-section">
                <div className="track-popover-heading">Size</div>
                <div className="track-popover-sizes">
                  {SUB_SIZES.map((s) => (
                    <button
                      key={s.id}
                      className={`track-popover-size-btn${s.id === subtitleSize ? ' active' : ''}`}
                      onClick={() => setSubtitleAppearance({ subtitleSize: s.id })}
                    >
                      {s.label}
                    </button>
                  ))}
                </div>
              </div>

              <div className="track-popover-section">
                <div className="track-popover-heading">Appearance</div>
                {SUB_STYLES.map((s) => (
                  <button
                    key={s.id}
                    className={`track-popover-item${s.id === subtitleStyle ? ' active' : ''}`}
                    onClick={() => setSubtitleAppearance({ subtitleStyle: s.id })}
                  >
                    <span className="track-popover-check">{s.id === subtitleStyle ? '✓' : ''}</span>
                    <span className="track-popover-label">{s.label}</span>
                  </button>
                ))}
              </div>
            </refractive.div>
          )}
        </div>

        <div className="video-player-seek-left">
          <span className="video-player-time-elapsed">{formatTime(Math.round(time))}</span>
          <div className="video-player-seek">
            <div className="video-player-seek-track">
              <div className="video-player-seek-fill" style={{ width: `${progressPct}%` }} />
              <div className="video-player-seek-head" style={{ left: `${progressPct}%` }} />
            </div>
            <input
              type="range"
              className="video-player-seek-input"
              min={0}
              max={totalDuration}
              step={1}
              value={time}
              onInput={handleSeekBarInput}
              onChange={handleSeekBarInput}
            />
          </div>
          <span className="video-player-time-remaining">-{formatTime(Math.max(0, Math.round(duration - time)))}</span>
        </div>
      </div>
    </div>,
    document.body
  )
}
