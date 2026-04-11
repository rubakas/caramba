import { useRef, useState, useEffect, useCallback } from 'react'
import { refractive } from '@hashintel/refractive'
import { usePlayer } from '../context/PlayerContext'
import { formatTime } from '../utils'
import { useGlassConfig } from '../config/useGlassConfig'

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

// Subtitle size presets
const SUB_SIZES = [
  { id: 'small',  label: 'S',  em: '0.7em' },
  { id: 'medium', label: 'M',  em: '0.9em' },
  { id: 'large',  label: 'L',  em: '1.2em' },
]

// Subtitle appearance presets
const SUB_STYLES = [
  { id: 'classic',     label: 'Classic',     css: 'background: rgba(0,0,0,0.75); color: #fff; text-shadow: none;' },
  { id: 'outline',     label: 'Outline',     css: 'background: transparent; color: #fff; text-shadow: -1px -1px 0 #000, 1px -1px 0 #000, -1px 1px 0 #000, 1px 1px 0 #000, 0 0 4px #000;' },
  { id: 'drop-shadow', label: 'Drop Shadow', css: 'background: transparent; color: #fff; text-shadow: 2px 2px 4px rgba(0,0,0,0.9), 0 0 8px rgba(0,0,0,0.6);' },
  { id: 'transparent', label: 'Transparent', css: 'background: rgba(0,0,0,0.4); color: #fff; text-shadow: none;' },
]

export default function VideoPlayer() {
  const { playerState, closePlayer, playNextEpisode, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance } = usePlayer()
  const videoRef = useRef(null)
  const containerRef = useRef(null)
  const hideTimerRef = useRef(null)
  const rafRef = useRef(null)
  const trackMenuRef = useRef(null)
  const clickTimerRef = useRef(null)

  // Seek generation counter to discard stale seek results from concurrent calls
  const seekGenRef = useRef(0)

  // seekBase tracks the absolute offset that ffmpeg's -ss was given.
  // video.currentTime is relative to this offset — so absolute time = seekBase + video.currentTime
  const seekBaseRef = useRef(0)

  const [paused, setPaused] = useState(false)
  const [currentTime, setCurrentTime] = useState(0) // absolute time
  const [buffering, setBuffering] = useState(true)
  const [controlsVisible, setControlsVisible] = useState(true)
  const [volume, setVolume] = useState(1)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [trackMenuOpen, setTrackMenuOpen] = useState(false)
  // Bumped on every seek/audio switch so the <track> element remounts
  // and fetches freshly time-shifted VTT from the protocol handler
  const [subtitleVersion, setSubtitleVersion] = useState(0)

  const totalDuration = playerState.duration || 0
  const subtitleSize = playerState.subtitleSize || 'medium'
  const subtitleStyle = playerState.subtitleStyle || 'classic'

  const closeBtnGlass = useGlassConfig('close-btn')
  const skipBtnGlass = useGlassConfig('skip-btn')
  const playBtnGlass = useGlassConfig('play-btn')
  const utilityPillGlass = useGlassConfig('utility-pill')
  const trackPopoverGlass = useGlassConfig('track-popover')

  // Reset local state when player opens with new session
  useEffect(() => {
    if (playerState.open) {
      seekBaseRef.current = playerState.startTime || 0
      setCurrentTime(playerState.startTime || 0)
      setPaused(false)
      setBuffering(true)
      setControlsVisible(true)
      setTrackMenuOpen(false)
    }
  }, [playerState.sessionId, playerState.open, playerState.startTime])

  // Lock body scroll when player is open
  useEffect(() => {
    if (!playerState.open) return
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = '' }
  }, [playerState.open])

  // Clean up all timers when player closes to prevent leaks
  useEffect(() => {
    if (!playerState.open) {
      clearTimeout(hideTimerRef.current)
      clearTimeout(clickTimerRef.current)
      hideTimerRef.current = null
      clickTimerRef.current = null
    }
  }, [playerState.open])

  // Helper: disable all text tracks on the video element.
  // This forces Chromium to clear any currently-rendered subtitle cue.
  const disableAllTextTracks = useCallback(() => {
    const video = videoRef.current
    if (!video) return
    for (let i = 0; i < video.textTracks.length; i++) {
      video.textTracks[i].mode = 'disabled'
    }
  }, [])

  // When subtitleUrl becomes null (subs turned off), explicitly disable all
  // text tracks so Chromium clears the last-painted cue from the overlay.
  useEffect(() => {
    if (playerState.open && !playerState.subtitleUrl) {
      disableAllTextTracks()
    }
  }, [playerState.open, playerState.subtitleUrl, disableAllTextTracks])

  // Force subtitle track to 'showing' — Chromium often ignores the `default`
  // attribute or resets the mode to 'hidden' when the video source changes.
  // Uses a ref to track whether subtitles should be active, so the interval
  // callback never forces a stale track to 'showing' after subs are turned off.
  const subtitleActiveRef = useRef(false)
  useEffect(() => {
    subtitleActiveRef.current = !!(playerState.open && playerState.subtitleUrl)
  }, [playerState.open, playerState.subtitleUrl])

  useEffect(() => {
    if (!playerState.open || !playerState.subtitleUrl) return

    const forceShowSubtitles = () => {
      // Bail out if subtitles were turned off between interval ticks
      if (!subtitleActiveRef.current) return
      const video = videoRef.current
      if (!video) return
      for (let i = 0; i < video.textTracks.length; i++) {
        if (video.textTracks[i].kind === 'subtitles') {
          video.textTracks[i].mode = 'showing'
        }
      }
    }

    // Force on various events where Chromium may reset the track mode
    const video = videoRef.current
    if (!video) return

    // Immediate attempt
    forceShowSubtitles()

    // After video loads metadata (track mode often resets here)
    video.addEventListener('loadedmetadata', forceShowSubtitles)
    video.addEventListener('loadeddata', forceShowSubtitles)
    video.addEventListener('canplay', forceShowSubtitles)

    // Periodic check — Chromium can reset track mode asynchronously
    const interval = setInterval(forceShowSubtitles, 1000)

    return () => {
      video.removeEventListener('loadedmetadata', forceShowSubtitles)
      video.removeEventListener('loadeddata', forceShowSubtitles)
      video.removeEventListener('canplay', forceShowSubtitles)
      clearInterval(interval)
      // On cleanup (subtitle switch, subs off, player close), disable all tracks
      // so Chromium clears any currently-rendered cue from the overlay
      disableAllTextTracks()
    }
  }, [playerState.open, playerState.subtitleUrl, subtitleVersion, disableAllTextTracks])

  // Inject dynamic <style> for ::cue (CSS custom properties don't work inside ::cue)
  useEffect(() => {
    const sizeObj = SUB_SIZES.find(s => s.id === subtitleSize) || SUB_SIZES[1]
    const styleObj = SUB_STYLES.find(s => s.id === subtitleStyle) || SUB_STYLES[0]

    const styleEl = document.createElement('style')
    styleEl.textContent = `.video-player-video::cue { font-size: ${sizeObj.em}; font-family: inherit; ${styleObj.css} }`
    document.head.appendChild(styleEl)

    return () => { document.head.removeChild(styleEl) }
  }, [subtitleSize, subtitleStyle])

  // --- requestAnimationFrame time polling ---
  // RAF is throttled (or stopped entirely) when the window is hidden,
  // minimised, or the display is asleep — but the <video> keeps playing.
  // We pair it with the native `timeupdate` event (fires ~4 Hz regardless
  // of visibility) so the progress bar never goes stale.
  const updateTime = useCallback(() => {
    const video = videoRef.current
    if (video && !video.paused && isFinite(video.currentTime) && video.currentTime > 0) {
      const abs = seekBaseRef.current + video.currentTime
      setCurrentTime(abs)
    }
  }, [])

  useEffect(() => {
    if (!playerState.open) return

    const tick = () => {
      updateTime()
      rafRef.current = requestAnimationFrame(tick)
    }

    rafRef.current = requestAnimationFrame(tick)

    // Fallback: timeupdate fires even when the page is in the background
    const video = videoRef.current
    if (video) video.addEventListener('timeupdate', updateTime)

    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current)
      if (video) video.removeEventListener('timeupdate', updateTime)
    }
  }, [playerState.open, updateTime])

  // Report progress to main process periodically
  useEffect(() => {
    if (!playerState.open) return

    const timer = setInterval(() => {
      const video = videoRef.current
      if (video && !video.paused && isFinite(video.currentTime) && video.currentTime > 0) {
        window.api.reportProgress(video.currentTime, totalDuration)
      }
    }, 3000)

    return () => clearInterval(timer)
  }, [playerState.open, totalDuration])

  // Show/hide controls on mouse activity
  const showControls = useCallback(() => {
    setControlsVisible(true)
    clearTimeout(hideTimerRef.current)
    hideTimerRef.current = setTimeout(() => {
      if (!paused && !trackMenuOpen) setControlsVisible(false)
    }, 3000)
  }, [paused, trackMenuOpen])

  // Always show controls when paused or menu is open
  useEffect(() => {
    if (paused || trackMenuOpen) {
      setControlsVisible(true)
      clearTimeout(hideTimerRef.current)
    } else {
      showControls()
    }
  }, [paused, trackMenuOpen, showControls])

  // Close track menu when clicking outside
  useEffect(() => {
    if (!trackMenuOpen) return
    const handleClickOutside = (e) => {
      if (trackMenuRef.current && !trackMenuRef.current.contains(e.target)) {
        setTrackMenuOpen(false)
      }
    }
    // Use setTimeout so the current click that opened the menu doesn't immediately close it
    const timer = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside)
    }, 0)
    return () => {
      clearTimeout(timer)
      document.removeEventListener('mousedown', handleClickOutside)
    }
  }, [trackMenuOpen])

  // Fullscreen change listener
  useEffect(() => {
    const handler = () => setIsFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', handler)
    return () => document.removeEventListener('fullscreenchange', handler)
  }, [])

  // --- Callbacks ---

  const handleClose = useCallback(() => {
    const video = videoRef.current
    const absTime = video ? seekBaseRef.current + (video.currentTime || 0) : seekBaseRef.current
    const dur = totalDuration
    if (document.fullscreenElement) {
      document.exitFullscreen()
    }
    closePlayer(absTime, dur)
  }, [closePlayer, totalDuration])

  const handleEnded = useCallback(() => {
    if (playerState.type === 'episode') {
      // Auto-play next episode in the series
      playNextEpisode()
    } else {
      // Movies or unknown type — just close
      handleClose()
    }
  }, [playerState.type, playNextEpisode, handleClose])

  const handleSeekRelative = useCallback(async (delta) => {
    const video = videoRef.current
    if (!video) return
    if (totalDuration <= 0) return

    const absoluteCurrent = seekBaseRef.current + (video.currentTime || 0)
    const newTime = Math.max(0, Math.min(absoluteCurrent + delta, totalDuration))

    // Increment generation — any in-flight seek with an older gen is stale
    const gen = ++seekGenRef.current

    // Clear stale subtitle cues immediately before the async seek
    disableAllTextTracks()
    setBuffering(true)
    try {
      const result = await window.api.seekPlayback(newTime)
      // Discard if a newer seek was initiated while we were waiting
      if (gen !== seekGenRef.current) return
      if (result && result.streamUrl) {
        seekBaseRef.current = result.seekTime ?? newTime
        setCurrentTime(seekBaseRef.current)
        setSubtitleVersion(v => v + 1)
        video.src = result.streamUrl + '?t=' + Date.now()
        video.load()
        video.play().catch(() => {})
      }
    } catch (err) {
      if (gen !== seekGenRef.current) return
      console.error('Seek failed:', err)
      setBuffering(false)
    }
  }, [totalDuration, disableAllTextTracks])

  const handleSeekBarChange = useCallback(async (e) => {
    const newTime = parseFloat(e.target.value)
    // Increment generation — any in-flight seek with an older gen is stale
    const gen = ++seekGenRef.current
    // Clear stale subtitle cues immediately before the async seek
    disableAllTextTracks()
    setBuffering(true)
    try {
      const result = await window.api.seekPlayback(newTime)
      // Discard if a newer seek was initiated while we were waiting
      if (gen !== seekGenRef.current) return
      if (result && result.streamUrl) {
        seekBaseRef.current = result.seekTime ?? newTime
        setCurrentTime(seekBaseRef.current)
        setSubtitleVersion(v => v + 1)
        const video = videoRef.current
        if (video) {
          video.src = result.streamUrl + '?t=' + Date.now()
          video.load()
          video.play().catch(() => {})
        }
      }
    } catch (err) {
      if (gen !== seekGenRef.current) return
      console.error('Seek bar failed:', err)
      setBuffering(false)
    }
  }, [disableAllTextTracks])

  const handleSwitchAudio = useCallback(async (audioStreamIndex) => {
    const video = videoRef.current
    if (!video) return

    setBuffering(true)
    const result = await switchAudio(audioStreamIndex, video.currentTime)
    if (result && result.streamUrl) {
      seekBaseRef.current = result.seekTime ?? seekBaseRef.current
      setCurrentTime(seekBaseRef.current)
      setSubtitleVersion(v => v + 1)
      video.src = result.streamUrl + '?t=' + Date.now()
      video.load()
      video.play().catch(() => {})
    } else {
      setBuffering(false)
    }
  }, [switchAudio])

  const handleSwitchSubtitle = useCallback(async (subtitleStreamIndex) => {
    // Disable all text tracks BEFORE the switch so Chromium clears the
    // currently-rendered cue.  The forceShowSubtitles effect will re-enable
    // the new track once React mounts the fresh <track> element.
    disableAllTextTracks()
    const result = await switchSubtitle(subtitleStreamIndex)
    // switchSubtitle updates playerState.subtitleUrl and activeSubtitleIndex.
    // React will re-render the <track> element (or remove it if subtitleUrl is null).
    // The forceShowSubtitles effect handles setting mode='showing' on the new track.
  }, [switchSubtitle, disableAllTextTracks])

  const handleSwitchBitmapSubtitle = useCallback(async (subtitleStreamIndex) => {
    const video = videoRef.current
    if (!video) return

    // Disable text tracks — bitmap subs are burned into the video stream
    disableAllTextTracks()
    setBuffering(true)
    const result = await switchBitmapSubtitle(subtitleStreamIndex, video.currentTime)
    if (result && result.streamUrl) {
      seekBaseRef.current = result.seekTime ?? seekBaseRef.current
      setCurrentTime(seekBaseRef.current)
      setSubtitleVersion(v => v + 1)
      video.src = result.streamUrl + '?t=' + Date.now()
      video.load()
      video.play().catch(() => {})
    } else {
      setBuffering(false)
    }
  }, [switchBitmapSubtitle, disableAllTextTracks])

  const toggleFullscreen = useCallback(() => {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else if (containerRef.current) {
      containerRef.current.requestFullscreen()
    }
  }, [])

  const handleVolumeChange = useCallback((e) => {
    const val = parseFloat(e.target.value)
    setVolume(val)
    if (videoRef.current) {
      videoRef.current.volume = val
      // Unmute when the user actively drags the slider to a non-zero value
      if (val > 0 && videoRef.current.muted) {
        videoRef.current.muted = false
      }
    }
  }, [])

  // --- Keyboard controls ---
  useEffect(() => {
    if (!playerState.open) return

    const handleKey = (e) => {
      const video = videoRef.current
      if (!video) return

      switch (e.key) {
        case ' ':
        case 'k':
          e.preventDefault()
          video.paused ? video.play() : video.pause()
          break
        case 'Escape':
          e.preventDefault()
          if (trackMenuOpen) {
            setTrackMenuOpen(false)
          } else {
            handleClose()
          }
          break
        case 'f':
          e.preventDefault()
          toggleFullscreen()
          break
        case 'ArrowLeft':
          e.preventDefault()
          handleSeekRelative(-10)
          break
        case 'ArrowRight':
          e.preventDefault()
          handleSeekRelative(10)
          break
        case 'ArrowUp':
          e.preventDefault()
          video.volume = Math.min(1, video.volume + 0.1)
          setVolume(video.volume)
          break
        case 'ArrowDown':
          e.preventDefault()
          video.volume = Math.max(0, video.volume - 0.1)
          setVolume(video.volume)
          break
        case 'm':
          e.preventDefault()
          video.muted = !video.muted
          break
      }
      showControls()
    }

    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [playerState.open, showControls, handleClose, toggleFullscreen, handleSeekRelative, trackMenuOpen])

  if (!playerState.open) return null

  const progressPct = totalDuration > 0 ? (currentTime / totalDuration) * 100 : 0

  return (
    <div
      ref={containerRef}
      className={`video-player-overlay${controlsVisible ? ' controls-visible' : ''}`}
      onMouseMove={showControls}
      onWheel={(e) => e.stopPropagation()}
    >
      {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
      <video
        ref={videoRef}
        className="video-player-video"
        src={playerState.streamUrl + '?t=' + playerState.sessionId}
        crossOrigin="anonymous"
        autoPlay
        onClick={(e) => {
          e.stopPropagation()
          showControls()
          if (trackMenuOpen) { setTrackMenuOpen(false); return }
          // Delay single-click (play/pause) to distinguish from double-click (fullscreen)
          if (clickTimerRef.current) {
            clearTimeout(clickTimerRef.current)
            clickTimerRef.current = null
            toggleFullscreen()
          } else {
            clickTimerRef.current = setTimeout(() => {
              clickTimerRef.current = null
              const v = videoRef.current
              if (v) v.paused ? v.play() : v.pause()
            }, 250)
          }
        }}
        onPlay={() => setPaused(false)}
        onPause={() => setPaused(true)}
        onWaiting={() => setBuffering(true)}
        onCanPlay={() => setBuffering(false)}
        onPlaying={() => setBuffering(false)}
        onEnded={handleEnded}
      >
        {playerState.subtitleUrl && (
          <track key={playerState.subtitleUrl + '-' + subtitleVersion} kind="subtitles" src={playerState.subtitleUrl + '&v=' + subtitleVersion} label="Subtitles" default />
        )}
      </video>

      {/* Top-right: close button */}
      <div
        className={`video-player-top${controlsVisible ? ' visible' : ''}`}
        onClick={(e) => e.stopPropagation()}
      >
        <refractive.button className="video-player-close" onClick={(e) => { e.stopPropagation(); handleClose() }} refraction={closeBtnGlass}>
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
            <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
          </svg>
        </refractive.button>
      </div>

      {/* Center playback controls: skip back, play/pause, skip forward */}
      <div
        className={`video-player-center${controlsVisible ? ' visible' : ''}`}
        onClick={(e) => e.stopPropagation()}
      >
        <refractive.button className="video-player-skip-btn" onClick={() => handleSeekRelative(-10)} refraction={skipBtnGlass}>
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>
          </svg>
          <span className="video-player-skip-num">10</span>
        </refractive.button>

        <refractive.button
          className="video-player-play-btn"
          onClick={() => {
            const v = videoRef.current
            if (v) v.paused ? v.play() : v.pause()
          }}
          refraction={playBtnGlass}
        >
          {buffering ? (
            <div className="spinner" style={{ width: 28, height: 28 }} />
          ) : paused ? (
            <svg width="36" height="36" viewBox="0 0 24 24" fill="currentColor"><polygon points="6 3 20 12 6 21"/></svg>
          ) : (
            <svg width="36" height="36" viewBox="0 0 24 24" fill="currentColor"><rect x="5" y="3" width="5" height="18" rx="1"/><rect x="14" y="3" width="5" height="18" rx="1"/></svg>
          )}
        </refractive.button>

        <refractive.button className="video-player-skip-btn" onClick={() => handleSeekRelative(30)} refraction={skipBtnGlass}>
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

        {/* Utility group: single glass pill, right column */}
        <div className="video-player-track-menu-anchor" ref={trackMenuRef}>
          <refractive.div className="video-player-utilities" refraction={utilityPillGlass}>
            {/* Volume slider */}
            <input
              type="range"
              className="video-player-volume-slider"
              min={0}
              max={1}
              step={0.05}
              value={volume}
              onChange={handleVolumeChange}
              style={{ background: `linear-gradient(to right, #fff 0%, #fff ${volume * 100}%, rgba(255,255,255,.3) ${volume * 100}%, rgba(255,255,255,.3) 100%)` }}
            />
            {/* Volume icon (mute toggle) */}
            <button className="video-player-util-icon" onClick={() => {
              const v = videoRef.current
              if (v) {
                v.muted = !v.muted
                setVolume(v.muted ? 0 : v.volume)
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
            {/* Settings icon */}
            <button
              className={`video-player-util-icon${trackMenuOpen ? ' active' : ''}`}
              onClick={() => setTrackMenuOpen(v => !v)}
              title="Audio & Subtitles"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
              </svg>
            </button>
            {/* Fullscreen icon */}
            <button className="video-player-util-icon" onClick={toggleFullscreen}>
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
              {/* Audio section */}
              {playerState.audioStreams.length > 1 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Audio</div>
                  {playerState.audioStreams.map((s) => (
                    <button
                      key={s.index}
                      className={`track-popover-item${s.index === playerState.activeAudioIndex ? ' active' : ''}`}
                      onClick={() => {
                        if (s.index !== playerState.activeAudioIndex) {
                          handleSwitchAudio(s.index)
                        }
                        setTrackMenuOpen(false)
                      }}
                    >
                      <span className="track-popover-check">
                        {s.index === playerState.activeAudioIndex ? '\u2713' : ''}
                      </span>
                      <span className="track-popover-label">{audioLabel(s)}</span>
                    </button>
                  ))}
                </div>
              )}

              {/* Subtitles section — show when there are any subtitles (text or bitmap) */}
              {playerState.subtitleStreams.length > 0 && (
                <div className="track-popover-section">
                  <div className="track-popover-heading">Subtitles</div>
                  <button
                    className={`track-popover-item${playerState.activeSubtitleIndex == null ? ' active' : ''}`}
                    onClick={() => {
                      if (playerState.activeSubtitleIndex != null) {
                        if (playerState.isBitmapSubtitle) {
                          handleSwitchBitmapSubtitle(null)
                        } else {
                          handleSwitchSubtitle(null)
                        }
                      }
                      setTrackMenuOpen(false)
                    }}
                  >
                    <span className="track-popover-check">
                      {playerState.activeSubtitleIndex == null ? '\u2713' : ''}
                    </span>
                    <span className="track-popover-label">Off</span>
                  </button>
                  {playerState.subtitleStreams.map((s) => (
                    <button
                      key={s.index}
                      className={`track-popover-item${s.index === playerState.activeSubtitleIndex ? ' active' : ''}`}
                      onClick={() => {
                        if (s.index !== playerState.activeSubtitleIndex) {
                          if (s.isText) {
                            // Switching to a text sub — if currently burning a bitmap, turn off burn first
                            if (playerState.isBitmapSubtitle) {
                              // Turn off burn-in, then switch to text extraction
                              handleSwitchBitmapSubtitle(null).then(() => {
                                handleSwitchSubtitle(s.index)
                              })
                            } else {
                              handleSwitchSubtitle(s.index)
                            }
                          } else {
                            // Bitmap sub — restart ffmpeg with overlay
                            handleSwitchBitmapSubtitle(s.index)
                          }
                        }
                        setTrackMenuOpen(false)
                      }}
                    >
                      <span className="track-popover-check">
                        {s.index === playerState.activeSubtitleIndex ? '\u2713' : ''}
                      </span>
                      <span className="track-popover-label">
                        {subtitleLabel(s)}{!s.isText ? ' (Bitmap)' : ''}
                      </span>
                    </button>
                  ))}
                </div>
              )}

              {/* Subtitle Size — only for text-based subtitles (::cue styling) */}
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

              {/* Subtitle Appearance — only for text-based subtitles (::cue styling) */}
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
                      {s.id === subtitleStyle ? '\u2713' : ''}
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
              onChange={handleSeekBarChange}
            />
          </div>
          <span className="video-player-time-remaining">-{formatTime(Math.max(0, Math.round(totalDuration - currentTime)))}</span>
        </div>
      </div>
    </div>
  )
}
