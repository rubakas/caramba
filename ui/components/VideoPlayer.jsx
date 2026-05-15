import { useRef, useState, useEffect, useCallback } from 'react'
import { Player } from '@jellyfin-rails/player'
import { refractive } from '../config/refractive'
import { usePlayer } from '../context/PlayerContext'
import { useApi, useCapabilities } from '../context/ApiContext'
import { useToast } from '../context/ToastContext'
import { formatTime } from '../utils'
import { useGlassConfig } from '../config/useGlassConfig'
import { useDebugPlayback } from '../hooks/useDebugPlayback'

// Human-readable language names for common ISO 639 codes
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
  return LANG_NAMES[code] || code.toUpperCase()
}

function audioLabel(stream) {
  const lang = langName(stream.language)
  const ch = stream.channels === 6 ? '5.1' : stream.channels === 8 ? '7.1' : stream.channels === 2 ? 'Stereo' : stream.channels === 1 ? 'Mono' : `${stream.channels}ch`
  const codec = (stream.codec || '').toUpperCase()
  return `${lang} (${codec} ${ch})`
}

function subtitleLabel(stream) {
  const lang = langName(stream.language)
  const info = stream.title || (stream.codec || '').toUpperCase()
  return info ? `${lang} — ${info}` : lang
}

// Overlay that surfaces what the playback pipeline is actually doing —
// which strategy was picked, source codec/res/bitrate, HDR transfer, audio
// layout. Gated by the "Show playback debug overlay" Settings toggle
// (default-on in dev builds, default-off in prod) — see
// `useDebugPlayback`.
function DevPlaybackInfo({ strategy, video, bitrate, audioStream }) {
  const [debugEnabled] = useDebugPlayback()
  if (!debugEnabled) return null

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
      position: 'absolute', top: 12, left: 12, zIndex: 9999,
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
          {(audioStream.codec || '?').toUpperCase()} {audioStream.channels}ch
          {audioStream.language && audioStream.language !== 'und' && ` ${audioStream.language}`}
        </div>
      )}
    </div>
  )
}

// Subtitle size presets
const SUB_SIZES = [
  { id: 'small',  label: 'S',  em: '1.4em' },
  { id: 'medium', label: 'M',  em: '1.9em' },
  { id: 'large',  label: 'L',  em: '2.6em' },
]

// Subtitle appearance presets
const SUB_STYLES = [
  { id: 'classic',     label: 'Classic',     css: 'background: rgba(0,0,0,0.75); color: #fff; text-shadow: none;' },
  { id: 'outline',     label: 'Outline',     css: 'background: transparent; color: #fff; text-shadow: -1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000, 1px 1px 0 #000, 0 0 4px #000;' },
  { id: 'drop-shadow', label: 'Drop Shadow', css: 'background: transparent; color: #fff; text-shadow: 2px 2px 4px rgba(0,0,0,0.9), 0 0 8px rgba(0,0,0,0.6);' },
  { id: 'transparent', label: 'Transparent', css: 'background: rgba(0,0,0,0.4); color: #fff; text-shadow: none;' },
]

// Native player branch — when the CarambaPlayer Capacitor plugin is present
// (Android TV native build) we skip the Player JS runtime entirely and let
// the plugin's full-screen ExoPlayer Activity render playback.
function NativeVideoPlayer() {
  const { playerState, launching, closePlayer, playNextEpisode, seekPlayback, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance } = usePlayer()
  const api = useApi()
  const lastRef = useRef({ open: false, hlsUrl: null, streamUrl: null, subtitleUrl: null, seekBase: 0, activeAudioIndex: null, activeSubtitleIndex: null })
  const presentedRef = useRef(false)
  const stateRef = useRef(playerState)
  useEffect(() => { stateRef.current = playerState }, [playerState])

  useEffect(() => {
    const plugin = window?.Capacitor?.Plugins?.CarambaPlayer
    if (!plugin) return

    const apiBase = api.baseUrl?.() || ''

    if (playerState.open && !lastRef.current.open) {
      if (launching && !presentedRef.current) {
        plugin.present?.({ apiBase, episodeId: playerState.episodeId || 0, movieId: playerState.movieId || 0 }).catch(() => {})
        presentedRef.current = true
      }
      lastRef.current = { open: true }
    }

    if (playerState.open && !launching && (playerState.hlsUrl || playerState.streamUrl)) {
      const payload = {
        sessionId: String(playerState.sessionId ?? ''),
        streamUrl: playerState.streamUrl ?? null,
        hlsUrl: playerState.hlsUrl ?? null,
        subtitleUrl: playerState.subtitleUrl ?? null,
        strategy: playerState.strategy ?? 'direct_stream',
        duration: playerState.duration || 0,
        startTime: playerState.startTime || 0,
        seekBase: playerState.seekBase || 0,
        title: playerState.title || '',
        subtitle: playerState.subtitle || '',
        audioStreams: playerState.audioStreams || [],
        subtitleStreams: playerState.subtitleStreams || [],
        activeAudioIndex: playerState.activeAudioIndex ?? null,
        activeSubtitleIndex: playerState.activeSubtitleIndex ?? null,
        isBitmapSubtitle: !!playerState.isBitmapSubtitle,
        video: playerState.video ?? null,
        apiBase,
        episodeId: playerState.episodeId || 0,
        movieId: playerState.movieId || 0,
        watchHistoryId: playerState.watchHistoryId || 0,
      }
      if (presentedRef.current) {
        plugin.updateStream?.(payload).catch(() => {})
      } else {
        plugin.present?.(payload).catch(() => {})
        presentedRef.current = true
      }
      lastRef.current = { open: true, ...payload }
    }

    if (!playerState.open && lastRef.current.open) {
      plugin.dismiss?.().catch(() => {})
      presentedRef.current = false
      lastRef.current = { open: false }
    }
  }, [api, playerState, launching])

  useEffect(() => {
    const plugin = window?.Capacitor?.Plugins?.CarambaPlayer
    if (!plugin) return

    const onClosed = plugin.addListener?.('playerClosed', () => {
      const cur = stateRef.current
      closePlayer(cur.currentTime || 0, cur.duration || 0)
    })
    const onEnded = plugin.addListener?.('playbackEnded', () => {
      const cur = stateRef.current
      if (cur.type === 'episode') playNextEpisode()
      else closePlayer(cur.currentTime || 0, cur.duration || 0)
    })

    return () => {
      onClosed?.then(h => h.remove?.())
      onEnded?.then(h => h.remove?.())
    }
  }, [closePlayer, playNextEpisode])

  return null
}

// Public component exported as the player surface.
export default function VideoPlayer() {
  const capabilities = useCapabilities()
  if (capabilities.hasNativePlayer) {
    return <NativeVideoPlayer />
  }
  return <WebVideoPlayer />
}

function WebVideoPlayer() {
  const { playerState, closePlayer, playNextEpisode, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance } = usePlayer()
  const api = useApi()
  const { showToast } = useToast()
  const playerMountRef = useRef(null)
  const playerRef = useRef(null)
  const containerRef = useRef(null)
  const hideTimerRef = useRef(null)
  const trackMenuRef = useRef(null)
  const clickTimerRef = useRef(null)
  const isTouchRef = useRef(false)
  const playBtnRef = useRef(null)

  const isAndroidTV = typeof window !== 'undefined' &&
    window.Capacitor?.isNativePlatform?.() === true

  const seekingRef = useRef(false)
  const seekBarDragging = useRef(false)
  const seekBarTarget = useRef(null)

  const [paused, setPaused] = useState(false)
  const [currentTime, setCurrentTime] = useState(0)
  // `loading` = the HTMLVideoElement is NOT actively playing frames.
  // Driven entirely by the player's own events:
  //   - true on mount (initial load), on `waiting` (buffer underrun)
  //     and on `seeking` (playhead moved, buffer needs to fill)
  //   - false on `playing` (the canonical "frames are being painted now"
  //     event from HTML5 video — distinct from `play` which only marks
  //     play() invocation)
  // No timers, no delta tracking, no parallel state — `loading` mirrors
  // exactly what the video element is doing, and the spinner just
  // renders it.
  const [loading, setLoading] = useState(true)
  // Throttle for /api/playback/report_progress — last reported time in
  // monotonic seconds. The player emits `progress` once per second; we
  // only forward to the server every REPORT_PROGRESS_INTERVAL_MS so the
  // request log stops drowning out everything else.
  const lastReportRef = useRef(0)
  const [controlsVisible, setControlsVisible] = useState(true)
  const [volume, setVolume] = useState(1)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [trackMenuOpen, setTrackMenuOpen] = useState(false)
  const [tvMode, setTvMode] = useState('seek')

  const totalDuration = playerState.duration || 0
  const subtitleSize = playerState.subtitleSize || 'medium'
  const subtitleStyle = playerState.subtitleStyle || 'classic'

  const closeBtnGlass = useGlassConfig('close-btn')
  const skipBtnGlass = useGlassConfig('skip-btn')
  const playBtnGlass = useGlassConfig('play-btn')
  const utilityPillGlass = useGlassConfig('utility-pill')
  const trackPopoverGlass = useGlassConfig('track-popover')

  // Reset local state when a new session opens.
  useEffect(() => {
    if (playerState.open) {
      setCurrentTime(playerState.seekBase ?? playerState.startTime ?? 0)
      setPaused(false)
      setLoading(true)
      lastReportRef.current = 0
      setControlsVisible(true)
      setTrackMenuOpen(false)
      setTvMode('seek')
      // Don't schedule an auto-hide here — the visibility effect below
      // owns that decision and gates it on `loading`. Setting a timer
      // here unconditionally hid the controls 3 s into the loading
      // window if the effect's clearTimeout raced with this setTimeout.
      clearTimeout(hideTimerRef.current)
      hideTimerRef.current = null
    }
  }, [playerState.sessionId, playerState.open])

  useEffect(() => {
    if (!playerState.open) return
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = '' }
  }, [playerState.open])

  useEffect(() => {
    if (!playerState.open) {
      clearTimeout(hideTimerRef.current)
      clearTimeout(clickTimerRef.current)
      hideTimerRef.current = null
      clickTimerRef.current = null
    }
  }, [playerState.open])

  // Instantiate Player JS for the current session. Recreated when the URL
  // changes (every audio/subtitle switch produces a new HLS master URL).
  useEffect(() => {
    if (!playerState.open) return
    const mount = playerMountRef.current
    if (!mount) return
    const url = playerState.hlsUrl || playerState.streamUrl
    if (!url) return

    const player = new Player(mount, {
      source: { hlsUrl: url },
      controls: false,
      keyboardShortcuts: false,
      autoplay: true,
      startAtSeconds: playerState.startTime || 0,
    })
    playerRef.current = player

    const offPlay    = player.on('play',    () => setPaused(false))
    const offPause   = player.on('pause',   () => setPaused(true))
    // Canonical "is the video actually playing" signal:
    //   playing → frames are being painted (loading=false)
    //   waiting → buffer underrun, frames stopped (loading=true)
    //   seeking → playhead moved, buffer needs to refill (loading=true)
    // These are HTMLMediaElement events; `loading` mirrors exactly what
    // the video element is doing, no parallel state to keep in sync.
    const offPlaying = player.on('playing', () => setLoading(false))
    const offWait    = player.on('waiting', () => setLoading(true))
    const offSeeking = player.on('seeking', () => setLoading(true))
    const offProg    = player.on('progress', ({ currentTime: t }) => {
      if (seekBarDragging.current) return
      if (seekingRef.current) return
      setCurrentTime(t)
      if (playerState.type !== 'episode' && playerState.type !== 'movie') return
      // Throttle the network call. The player emits `progress` every
      // ~1 s; reporting that frequently spams Rails with a transaction
      // per second and adds nothing — server-side bookkeeping only
      // needs second-level resolution at multi-second granularity.
      // 5 s matches what Jellyfin's official clients use.
      const REPORT_PROGRESS_INTERVAL_S = 5
      if (Math.abs(t - lastReportRef.current) < REPORT_PROGRESS_INTERVAL_S) return
      lastReportRef.current = t
      api.reportProgress(t, playerState.duration || 0, {
        type: playerState.type,
        episodeId: playerState.episodeId,
        movieId: playerState.movieId,
        watchHistoryId: playerState.watchHistoryId,
      })
    })
    const offEnded  = player.on('ended', () => {
      if (playerState.type === 'episode') playNextEpisode()
      else closePlayer(playerState.duration || 0, playerState.duration || 0)
    })
    const offError  = player.on('error', ({ message }) => {
      console.warn('[Player] error:', message)
      showToast('Playback failed: ' + (message || 'unknown error'), { type: 'error', duration: 6000 })
      closePlayer()
    })
    const offVol    = player.on('volumechange', ({ volume: v }) => setVolume(v))

    player.load().catch((err) => {
      console.error('[Player] load failed', err)
    })

    return () => {
      offPlay?.(); offPause?.(); offPlaying?.(); offWait?.(); offSeeking?.(); offProg?.()
      offEnded?.(); offError?.(); offVol?.()
      try { player.destroy() } catch {}
      playerRef.current = null
    }
  }, [playerState.open, playerState.sessionId, playerState.hlsUrl, playerState.streamUrl,
      playerState.startTime, playerState.type, playerState.episodeId, playerState.movieId,
      playerState.watchHistoryId, playerState.duration, api, closePlayer, playNextEpisode, showToast])

  // Inject dynamic ::cue styling for the current size/style preset.
  useEffect(() => {
    const sizeObj = SUB_SIZES.find(s => s.id === subtitleSize) || SUB_SIZES[1]
    const styleObj = SUB_STYLES.find(s => s.id === subtitleStyle) || SUB_STYLES[0]

    const styleEl = document.createElement('style')
    styleEl.textContent = `.jellyfin-player video::cue { font-size: ${sizeObj.em}; font-family: inherit; ${styleObj.css} }`
    document.head.appendChild(styleEl)

    return () => { document.head.removeChild(styleEl) }
  }, [subtitleSize, subtitleStyle])

  const showControls = useCallback(() => {
    setControlsVisible(true)
    clearTimeout(hideTimerRef.current)
    hideTimerRef.current = setTimeout(() => {
      // Auto-hide only while the spinner is OFF and playback is actually
      // running. `loading` covers initial load AND any mid-stream stall,
      // so a single check keeps the controls visible whenever the
      // spinner is. Pause and track-menu open both pin them open via the
      // effect below.
      if (!paused && !trackMenuOpen && !loading &&
          (!isAndroidTV || tvMode === 'seek')) {
        setControlsVisible(false)
      }
    }, 3000)
  }, [paused, trackMenuOpen, loading, isAndroidTV, tvMode])

  useEffect(() => {
    if (paused || trackMenuOpen || loading) {
      setControlsVisible(true)
      clearTimeout(hideTimerRef.current)
    } else {
      showControls()
    }
  }, [paused, trackMenuOpen, loading, showControls])

  useEffect(() => {
    if (isAndroidTV && controlsVisible && playBtnRef.current && !trackMenuOpen) {
      const activeEl = document.activeElement
      const isVideoOrBody = !activeEl || activeEl === document.body
      if (isVideoOrBody) {
        playBtnRef.current.focus({ preventScroll: true })
      }
    }
  }, [controlsVisible, isAndroidTV, trackMenuOpen])

  useEffect(() => {
    if (!trackMenuOpen) return
    const handleClickOutside = (e) => {
      if (trackMenuRef.current && !trackMenuRef.current.contains(e.target)) {
        setTrackMenuOpen(false)
      }
    }
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 0)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [trackMenuOpen])

  useEffect(() => {
    const handler = () => setIsFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', handler)
    return () => document.removeEventListener('fullscreenchange', handler)
  }, [])

  const handleClose = useCallback(() => {
    const absTime = playerRef.current?.currentTime ?? 0
    const dur = totalDuration
    if (document.fullscreenElement) document.exitFullscreen()
    closePlayer(absTime, dur)
  }, [closePlayer, totalDuration])

  const handleEnded = useCallback(() => {
    if (playerState.type === 'episode') playNextEpisode()
    else handleClose()
  }, [playerState.type, playNextEpisode, handleClose])

  const doSeek = useCallback((absoluteTime) => {
    const player = playerRef.current
    if (!player) return
    seekingRef.current = true
    try { player.seek(absoluteTime) } catch {}
    setCurrentTime(absoluteTime)
    // Player emits 'progress' shortly after — clear the flag after a tick.
    setTimeout(() => { seekingRef.current = false }, 100)
  }, [])

  const handleSeekRelative = useCallback((delta) => {
    const player = playerRef.current
    if (!player) return
    if (totalDuration <= 0) return
    const currentAbs = player.currentTime || 0
    const newTime = Math.max(0, Math.min(currentAbs + delta, totalDuration))
    doSeek(newTime)
  }, [totalDuration, doSeek])

  const handleSeekBarInput = useCallback((e) => {
    seekBarDragging.current = true
    seekBarTarget.current = parseFloat(e.target.value)
    setCurrentTime(seekBarTarget.current)
  }, [])

  const handleSeekBarCommit = useCallback(() => {
    if (!seekBarDragging.current || seekBarTarget.current == null) return
    seekBarDragging.current = false
    const newTime = seekBarTarget.current
    seekBarTarget.current = null
    doSeek(newTime)
  }, [doSeek])

  const handleSwitchAudio = useCallback(async (audioStreamIndex) => {
    const player = playerRef.current
    const currentVideoTime = player?.currentTime || 0
    setLoading(true)
    const result = await switchAudio(audioStreamIndex, currentVideoTime)
    if (!result) setLoading(false)
  }, [switchAudio])

  const handleSwitchSubtitle = useCallback(async (subtitleStreamIndex) => {
    setLoading(true)
    const result = await switchSubtitle(subtitleStreamIndex)
    if (!result) setLoading(false)
  }, [switchSubtitle])

  const handleSwitchBitmapSubtitle = useCallback(async (subtitleStreamIndex) => {
    const player = playerRef.current
    const currentVideoTime = player?.currentTime || 0
    setLoading(true)
    const result = await switchBitmapSubtitle(subtitleStreamIndex, currentVideoTime)
    if (!result) setLoading(false)
  }, [switchBitmapSubtitle])

  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else if (containerRef.current) {
      containerRef.current.requestFullscreen?.()
    }
  }, [])

  const handleVolumeChange = useCallback((e) => {
    const val = parseFloat(e.target.value)
    setVolume(val)
    playerRef.current?.setVolume(val)
  }, [])

  useEffect(() => {
    if (!playerState.open || !isAndroidTV) return

    const setupBackHandler = async () => {
      try {
        const { App } = await import('@capacitor/app')
        const backHandler = App.addListener('backButton', () => {
          if (tvMode === 'audio' || tvMode === 'subtitles') setTvMode('seek')
          else if (trackMenuOpen) setTrackMenuOpen(false)
          else handleClose()
        })
        return () => { backHandler.then(h => h.remove()) }
      } catch (err) {
        console.warn('[Player] back handler unavailable:', err)
      }
    }

    const cleanup = setupBackHandler()
    return () => { cleanup?.then(fn => fn?.()) }
  }, [playerState.open, isAndroidTV, trackMenuOpen, handleClose, tvMode])

  useEffect(() => {
    if (!playerState.open) return

    const handleKey = (e) => {
      const player = playerRef.current
      if (!player) return

      if (isAndroidTV) {
        switch (e.key) {
          case 'Enter':
            e.preventDefault()
            if (tvMode === 'seek') player.paused ? player.play() : player.pause()
            break
          case 'Escape':
          case 'GoBack':
            e.preventDefault()
            if (tvMode === 'audio' || tvMode === 'subtitles') setTvMode('seek')
            else handleClose()
            break
          case 'ArrowLeft':
            if (tvMode === 'seek') { e.preventDefault(); handleSeekRelative(-10); showControls() }
            break
          case 'ArrowRight':
            if (tvMode === 'seek') { e.preventDefault(); handleSeekRelative(10); showControls() }
            break
          case 'ArrowUp':
            if (tvMode === 'seek') { e.preventDefault(); setTvMode('audio') }
            break
          case 'ArrowDown':
            if (tvMode === 'seek') { e.preventDefault(); setTvMode('subtitles') }
            break
          case 'MediaPlayPause':
          case 'MediaPlay':
          case 'MediaPause':
            e.preventDefault()
            player.paused ? player.play() : player.pause()
            break
          case 'MediaStop':
            e.preventDefault(); handleClose(); break
          case 'MediaRewind':
            e.preventDefault(); handleSeekRelative(-30); break
          case 'MediaFastForward':
            e.preventDefault(); handleSeekRelative(30); break
        }
        return
      }

      switch (e.key) {
        case ' ':
        case 'k':
        case 'Enter':
          e.preventDefault()
          player.paused ? player.play() : player.pause()
          break
        case 'Escape':
          e.preventDefault()
          if (trackMenuOpen) setTrackMenuOpen(false)
          else handleClose()
          break
        case 'f':
          e.preventDefault(); toggleFullscreen(); break
        case 'ArrowLeft':
          e.preventDefault(); handleSeekRelative(-10); showControls(); break
        case 'ArrowRight':
          e.preventDefault(); handleSeekRelative(10); showControls(); break
        case 'ArrowUp':
          e.preventDefault()
          player.setVolume(Math.min(1, (player.volume ?? volume) + 0.1))
          break
        case 'ArrowDown':
          e.preventDefault()
          player.setVolume(Math.max(0, (player.volume ?? volume) - 0.1))
          break
        case 'm':
          e.preventDefault()
          // Player doesn't expose mute; toggle via volume → 0.
          if ((player.volume ?? volume) > 0) {
            player.setVolume(0)
          } else {
            player.setVolume(1)
          }
          break
        case 'MediaPlayPause':
        case 'MediaPlay':
        case 'MediaPause':
          e.preventDefault()
          player.paused ? player.play() : player.pause()
          break
        case 'MediaStop':
          e.preventDefault(); handleClose(); break
        case 'MediaRewind':
          e.preventDefault(); handleSeekRelative(-30); break
        case 'MediaFastForward':
          e.preventDefault(); handleSeekRelative(30); break
      }
    }

    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [playerState.open, showControls, handleClose, toggleFullscreen, handleSeekRelative, trackMenuOpen, isAndroidTV, tvMode, volume])

  if (!playerState.open) return null

  const progressPct = totalDuration > 0 ? (currentTime / totalDuration) * 100 : 0

  if (isAndroidTV) {
    const tvControlsHidden = !controlsVisible && !paused && !loading && tvMode === 'seek'
    const isSettingsMode = tvMode === 'audio' || tvMode === 'subtitles'

    return (
      <div
        ref={containerRef}
        className={`video-player-overlay controls-visible tv-player${isSettingsMode ? ' tv-settings-mode' : ''}`}
      >
        <DevPlaybackInfo
          strategy={playerState.strategy}
          video={playerState.video}
          bitrate={playerState.bitrate}
          audioStream={playerState.audioStreams?.find(s => s.index === playerState.activeAudioIndex)}
        />

        <div ref={playerMountRef} className="video-player-mount" style={{ position: 'absolute', inset: 0 }} />

        {!tvControlsHidden && (
          <div className="video-player-tv-top">
            <span className="video-player-bottom-title">{playerState.title}</span>
            {playerState.subtitle && (
              <span className="video-player-bottom-subtitle">{playerState.subtitle}</span>
            )}
          </div>
        )}

        {(paused || loading) && (
          <div className="video-player-tv-center">
            {loading ? (
              <div className="spinner" style={{ width: 48, height: 48 }} />
            ) : (
              <svg width="64" height="64" viewBox="0 0 24 24" fill="currentColor" opacity="0.9">
                <rect x="5" y="3" width="5" height="18" rx="1"/>
                <rect x="14" y="3" width="5" height="18" rx="1"/>
              </svg>
            )}
          </div>
        )}

        {tvMode === 'seek' && !tvControlsHidden && (
          <div className="video-player-tv-bottom">
            <div className="video-player-tv-seek">
              <span className="video-player-time-elapsed">{formatTime(Math.round(currentTime))}</span>
              <div className="tv-progress-bar">
                <div className="tv-progress-track">
                  <div className="tv-progress-fill" style={{ width: `${progressPct}%` }} />
                </div>
                <div className="tv-progress-head" style={{ left: `${progressPct}%` }} />
              </div>
              <span className="video-player-time-remaining">-{formatTime(Math.max(0, Math.round(totalDuration - currentTime)))}</span>
            </div>
            <div className="video-player-tv-hint">
              <span>◀ ▶ Seek</span>
              <span>OK Play/Pause</span>
              <span>▲ Audio</span>
              <span>▼ Subtitles</span>
            </div>
          </div>
        )}

        {tvMode === 'audio' && (
          <div className="video-player-tv-settings" onClick={(e) => e.stopPropagation()}>
            <div className="tv-settings-panel">
              <div className="track-popover-section">
                <div className="track-popover-heading">Audio</div>
                {playerState.audioStreams.length > 1 ? (
                  playerState.audioStreams.map((s, idx) => {
                    const handleSelect = () => {
                      if (s.index !== playerState.activeAudioIndex) handleSwitchAudio(s.index)
                      setTvMode('seek')
                    }
                    return (
                      <button
                        key={s.index}
                        tabIndex={0}
                        autoFocus={idx === 0}
                        className={`track-popover-item${s.index === playerState.activeAudioIndex ? ' active' : ''}`}
                        onClick={(e) => { e.stopPropagation(); handleSelect() }}
                        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); handleSelect() } }}
                      >
                        <span className="track-popover-check">
                          {s.index === playerState.activeAudioIndex ? '✓' : ''}
                        </span>
                        <span className="track-popover-label">{audioLabel(s)}</span>
                      </button>
                    )
                  })
                ) : (
                  <button tabIndex={0} autoFocus className="track-popover-item active" onClick={() => setTvMode('seek')} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); setTvMode('seek') } }}>
                    <span className="track-popover-check">{'✓'}</span>
                    <span className="track-popover-label">{playerState.audioStreams[0] ? audioLabel(playerState.audioStreams[0]) : 'Default'}</span>
                  </button>
                )}
              </div>
            </div>
            <div className="video-player-tv-hint">
              <span>▲ ▼ Navigate</span>
              <span>OK Select</span>
              <span>Back Return</span>
            </div>
          </div>
        )}

        {tvMode === 'subtitles' && (
          <div className="video-player-tv-settings" onClick={(e) => e.stopPropagation()}>
            <div className="tv-settings-panel">
              <div className="track-popover-section">
                <div className="track-popover-heading">Subtitles</div>
                {playerState.subtitleStreams.length > 0 ? (
                  <>
                    {(() => {
                      const handleOffSelect = () => {
                        if (playerState.activeSubtitleIndex != null) {
                          if (playerState.isBitmapSubtitle) handleSwitchBitmapSubtitle(null)
                          else handleSwitchSubtitle(null)
                        }
                        setTvMode('seek')
                      }
                      return (
                        <button
                          tabIndex={0}
                          autoFocus
                          className={`track-popover-item${playerState.activeSubtitleIndex == null ? ' active' : ''}`}
                          onClick={(e) => { e.stopPropagation(); handleOffSelect() }}
                          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); handleOffSelect() } }}
                        >
                          <span className="track-popover-check">
                            {playerState.activeSubtitleIndex == null ? '✓' : ''}
                          </span>
                          <span className="track-popover-label">Off</span>
                        </button>
                      )
                    })()}
                    {playerState.subtitleStreams.map((s) => {
                      const handleSelect = () => {
                        if (s.isText) {
                          if (playerState.isBitmapSubtitle) {
                            handleSwitchBitmapSubtitle(null).then(() => handleSwitchSubtitle(s.index))
                          } else {
                            handleSwitchSubtitle(s.index)
                          }
                        } else if (s.index !== playerState.activeSubtitleIndex) {
                          handleSwitchBitmapSubtitle(s.index)
                        }
                        setTvMode('seek')
                      }
                      return (
                        <button
                          key={s.index}
                          tabIndex={0}
                          className={`track-popover-item${s.index === playerState.activeSubtitleIndex ? ' active' : ''}`}
                          onClick={(e) => { e.stopPropagation(); handleSelect() }}
                          onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); handleSelect() } }}
                        >
                          <span className="track-popover-check">
                            {s.index === playerState.activeSubtitleIndex ? '✓' : ''}
                          </span>
                          <span className="track-popover-label">
                            {subtitleLabel(s)}{!s.isText ? ' (Bitmap)' : ''}
                          </span>
                        </button>
                      )
                    })}
                  </>
                ) : (
                  <button tabIndex={0} autoFocus className="track-popover-item active" onClick={() => setTvMode('seek')} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); setTvMode('seek') } }}>
                    <span className="track-popover-check">{'✓'}</span>
                    <span className="track-popover-label">None Available</span>
                  </button>
                )}
              </div>

              <div className="track-popover-section">
                <div className="track-popover-heading">Size</div>
                {SUB_SIZES.map((s) => {
                  const isDisabled = playerState.isBitmapSubtitle || playerState.activeSubtitleIndex == null
                  const handleSelect = () => {
                    if (!isDisabled) setSubtitleAppearance({ subtitleSize: s.id })
                  }
                  return (
                    <button
                      key={s.id}
                      tabIndex={isDisabled ? -1 : 0}
                      className={`track-popover-item${s.id === subtitleSize ? ' active' : ''}${isDisabled ? ' disabled' : ''}`}
                      onClick={(e) => { e.stopPropagation(); handleSelect() }}
                      onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); handleSelect() } }}
                    >
                      <span className="track-popover-check">
                        {s.id === subtitleSize ? '✓' : ''}
                      </span>
                      <span className="track-popover-label">{s.label}</span>
                    </button>
                  )
                })}
              </div>

              <div className="track-popover-section">
                <div className="track-popover-heading">Style</div>
                {SUB_STYLES.map((s) => {
                  const isDisabled = playerState.isBitmapSubtitle || playerState.activeSubtitleIndex == null
                  const handleSelect = () => {
                    if (!isDisabled) setSubtitleAppearance({ subtitleStyle: s.id })
                  }
                  return (
                    <button
                      key={s.id}
                      tabIndex={isDisabled ? -1 : 0}
                      className={`track-popover-item${s.id === subtitleStyle ? ' active' : ''}${isDisabled ? ' disabled' : ''}`}
                      onClick={(e) => { e.stopPropagation(); handleSelect() }}
                      onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); handleSelect() } }}
                    >
                      <span className="track-popover-check">
                        {s.id === subtitleStyle ? '✓' : ''}
                      </span>
                      <span className="track-popover-label">{s.label}</span>
                    </button>
                  )
                })}
              </div>
            </div>
            <div className="video-player-tv-hint">
              <span>◀ ▶ ▲ ▼ Navigate</span>
              <span>OK Select</span>
              <span>Back Return</span>
            </div>
          </div>
        )}
      </div>
    )
  }

  const activeAudio = playerState.audioStreams?.find(s => s.index === playerState.activeAudioIndex)
  return (
    <div
      ref={containerRef}
      className={`video-player-overlay${controlsVisible ? ' controls-visible' : ''}`}
      onMouseMove={showControls}
      onWheel={(e) => e.stopPropagation()}
    >
      <DevPlaybackInfo
        strategy={playerState.strategy}
        video={playerState.video}
        bitrate={playerState.bitrate}
        audioStream={activeAudio}
      />

      <div
        ref={playerMountRef}
        className="video-player-mount"
        style={{ position: 'absolute', inset: 0 }}
        onTouchStart={(e) => { isTouchRef.current = true; e.stopPropagation(); showControls() }}
        onClick={(e) => {
          e.stopPropagation()
          if (isTouchRef.current) { isTouchRef.current = false; return }
          showControls()
          if (trackMenuOpen) { setTrackMenuOpen(false); return }
          if (clickTimerRef.current) {
            clearTimeout(clickTimerRef.current)
            clickTimerRef.current = null
            toggleFullscreen()
          } else {
            clickTimerRef.current = setTimeout(() => {
              clickTimerRef.current = null
              const p = playerRef.current
              if (p) p.paused ? p.play() : p.pause()
            }, 250)
          }
        }}
      />

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
          ref={playBtnRef}
          className="video-player-play-btn"
          tabIndex={0}
          onClick={() => {
            const p = playerRef.current
            if (p) p.paused ? p.play() : p.pause()
          }}
          refraction={playBtnGlass}
        >
          {loading ? (
            <div className="spinner" style={{ width: 28, height: 28 }} />
          ) : paused ? (
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
              const p = playerRef.current
              if (!p) return
              if ((p.volume ?? volume) > 0) {
                p.setVolume(0); setVolume(0)
              } else {
                p.setVolume(1); setVolume(1)
              }
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
              {playerState.audioStreams.length > 1 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Audio</div>
                  {playerState.audioStreams.map((s, idx) => (
                    <button
                      key={s.index}
                      tabIndex={0}
                      autoFocus={idx === 0}
                      className={`track-popover-item${s.index === playerState.activeAudioIndex ? ' active' : ''}`}
                      onClick={() => {
                        if (s.index !== playerState.activeAudioIndex) handleSwitchAudio(s.index)
                        setTrackMenuOpen(false)
                      }}
                    >
                      <span className="track-popover-check">
                        {s.index === playerState.activeAudioIndex ? '✓' : ''}
                      </span>
                      <span className="track-popover-label">{audioLabel(s)}</span>
                    </button>
                  ))}
                </div>
              )}

              {playerState.subtitleStreams.length > 0 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Subtitles</div>
                  <button
                    tabIndex={0}
                    autoFocus={playerState.audioStreams.length <= 1}
                    className={`track-popover-item${playerState.activeSubtitleIndex == null ? ' active' : ''}`}
                    onClick={() => {
                      if (playerState.activeSubtitleIndex != null) {
                        if (playerState.isBitmapSubtitle) handleSwitchBitmapSubtitle(null)
                        else handleSwitchSubtitle(null)
                      }
                      setTrackMenuOpen(false)
                    }}
                  >
                    <span className="track-popover-check">
                      {playerState.activeSubtitleIndex == null ? '✓' : ''}
                    </span>
                    <span className="track-popover-label">Off</span>
                  </button>
                  {playerState.subtitleStreams.map((s) => (
                    <button
                      key={s.index}
                      tabIndex={0}
                      className={`track-popover-item${s.index === playerState.activeSubtitleIndex ? ' active' : ''}`}
                      onClick={() => {
                        if (s.isText) {
                          if (playerState.isBitmapSubtitle) {
                            handleSwitchBitmapSubtitle(null).then(() => handleSwitchSubtitle(s.index))
                          } else {
                            handleSwitchSubtitle(s.index)
                          }
                        } else if (s.index !== playerState.activeSubtitleIndex) {
                          handleSwitchBitmapSubtitle(s.index)
                        }
                        setTrackMenuOpen(false)
                      }}
                    >
                      <span className="track-popover-check">
                        {s.index === playerState.activeSubtitleIndex ? '✓' : ''}
                      </span>
                      <span className="track-popover-label">
                        {subtitleLabel(s)}{!s.isText ? ' (Bitmap)' : ''}
                      </span>
                    </button>
                  ))}
                </div>
              )}

              {!playerState.isBitmapSubtitle && (
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
              )}

              {!playerState.isBitmapSubtitle && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Appearance</div>
                  {SUB_STYLES.map((s) => (
                    <button
                      key={s.id}
                      className={`track-popover-item${s.id === subtitleStyle ? ' active' : ''}`}
                      onClick={() => setSubtitleAppearance({ subtitleStyle: s.id })}
                    >
                      <span className="track-popover-check">
                        {s.id === subtitleStyle ? '✓' : ''}
                      </span>
                      <span className="track-popover-label">{s.label}</span>
                    </button>
                  ))}
                </div>
              )}
            </refractive.div>
          )}
        </div>

        <div className="video-player-seek-left">
          <span className="video-player-time-elapsed">{formatTime(Math.round(currentTime))}</span>
          <div className="video-player-seek">
            <div className="video-player-seek-track">
              <div className="video-player-seek-fill" style={{ width: `${progressPct}%` }} />
              <div className="video-player-seek-head" style={{ left: `${progressPct}%` }} />
            </div>
            <input
              type="range"
              className="video-player-seek-input"
              min={0}
              max={totalDuration || 1}
              step={1}
              value={currentTime}
              onInput={handleSeekBarInput}
              onChange={handleSeekBarInput}
              onMouseUp={handleSeekBarCommit}
              onTouchEnd={handleSeekBarCommit}
            />
          </div>
          <span className="video-player-time-remaining">-{formatTime(Math.max(0, Math.round(totalDuration - currentTime)))}</span>
        </div>
      </div>
    </div>
  )
}
