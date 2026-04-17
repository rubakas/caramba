import { useRef, useState, useEffect, useCallback } from 'react'
import Hls from 'hls.js'
import { refractive } from '../config/refractive'
import { usePlayer } from '../context/PlayerContext'
import { useApi } from '../context/ApiContext'
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
  const { playerState, closePlayer, playNextEpisode, seekPlayback, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance } = usePlayer()
  const api = useApi()
  const videoRef = useRef(null)
  const containerRef = useRef(null)
  const hideTimerRef = useRef(null)
  const rafRef = useRef(null)
   const trackMenuRef = useRef(null)
   const clickTimerRef = useRef(null)
   const isTouchRef = useRef(false)
   const playBtnRef = useRef(null)  // For TV auto-focus

  // Detect Android TV for different control scheme
  const isAndroidTV = typeof window !== 'undefined' && 
    window.Capacitor?.isNativePlatform?.() === true

  // seekBase: the absolute time (in the source file) that corresponds to
  // video.currentTime === 0 in the current stream.  After a seek/restart,
  // ffmpeg starts from seekBase, so the video element's timeline resets to 0.
  // Absolute time = seekBase + video.currentTime.
  const seekBaseRef = useRef(0)

  const [paused, setPaused] = useState(false)
  const [currentTime, setCurrentTime] = useState(0) // absolute time for display
  const [buffering, setBuffering] = useState(true)
  const [controlsVisible, setControlsVisible] = useState(true)
  const [volume, setVolume] = useState(1)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [trackMenuOpen, setTrackMenuOpen] = useState(false)
  // Bumped on every seek/audio switch so the <track> element remounts
  const [subtitleVersion, setSubtitleVersion] = useState(0)
  // TV mode: 'seek' (default) or 'settings'
  const [tvMode, setTvMode] = useState('seek')

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
      seekBaseRef.current = playerState.seekBase ?? playerState.startTime ?? 0
      setCurrentTime(seekBaseRef.current)
      setPaused(false)
      setBuffering(true)
      setControlsVisible(true)
      setTrackMenuOpen(false)
      setTvMode('seek')
      // Start the auto-hide timer
      clearTimeout(hideTimerRef.current)
      hideTimerRef.current = setTimeout(() => {
        setControlsVisible(false)
      }, 3000)
    }
  }, [playerState.sessionId, playerState.open])

  // Lock body scroll when player is open
  useEffect(() => {
    if (!playerState.open) return
    document.body.style.overflow = 'hidden'
    return () => { document.body.style.overflow = '' }
  }, [playerState.open])

  // Clean up all timers when player closes
  useEffect(() => {
    if (!playerState.open) {
      clearTimeout(hideTimerRef.current)
      clearTimeout(clickTimerRef.current)
      hideTimerRef.current = null
      clickTimerRef.current = null
    }
  }, [playerState.open])

  // ── Source attachment ─────────────────────────────────────────────
  // All platforms are fed an HLS manifest:
  //   - Safari / iOS — native HLS via <video src="…m3u8">
  //   - Chromium / Firefox / Android WebView — hls.js
  // Desktop Electron serves the same manifest via the stream:// protocol;
  // the fetch/playback code path is identical.
  const hlsRef = useRef(null)

  const cleanupSource = useCallback(() => {
    if (hlsRef.current) {
      try { hlsRef.current.destroy() } catch {}
      hlsRef.current = null
    }
  }, [])

  useEffect(() => {
    if (!playerState.open) return
    const video = videoRef.current
    if (!video) return

    const manifestUrl = playerState.hlsUrl || playerState.streamUrl
    if (!manifestUrl) return

    cleanupSource()

    const useNativeHls = video.canPlayType('application/vnd.apple.mpegurl')

    if (useNativeHls) {
      console.log('[Player] Native HLS:', manifestUrl)
      video.src = manifestUrl
      video.load()
      video.play().catch((err) => console.warn('[Player] play rejected:', err.message))
    } else if (Hls.isSupported()) {
      console.log('[Player] hls.js:', manifestUrl)
      const hls = new Hls({
        // Conservative buffer caps — Android TV WebView has tight memory limits.
        maxBufferLength: 30,                // seconds forward
        maxMaxBufferLength: 60,             // seconds hard cap
        maxBufferSize: 60 * 1024 * 1024,    // 60 MB
        backBufferLength: 15,               // seconds behind playhead
        // Retry transient network errors before giving up
        manifestLoadingMaxRetry: 5,
        manifestLoadingRetryDelay: 1000,
        levelLoadingMaxRetry: 5,
        levelLoadingRetryDelay: 1000,
        fragLoadingMaxRetry: 5,
        fragLoadingRetryDelay: 1000,
      })
      hlsRef.current = hls
      hls.loadSource(manifestUrl)
      hls.attachMedia(video)

      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        video.play().catch((err) => console.warn('[Player] play rejected:', err.message))
      })

      hls.on(Hls.Events.ERROR, (_event, data) => {
        if (!data.fatal) {
          console.log('[Player] hls.js non-fatal:', data.type, data.details)
          return
        }
        console.warn('[Player] hls.js fatal:', data.type, data.details)
        switch (data.type) {
          case Hls.ErrorTypes.NETWORK_ERROR:
            hls.startLoad()
            break
          case Hls.ErrorTypes.MEDIA_ERROR:
            hls.recoverMediaError()
            break
          default:
            cleanupSource()
        }
      })
    } else {
      console.warn('[Player] No HLS support; falling back to direct src')
      video.src = manifestUrl
      video.load()
      video.play().catch(() => {})
    }

    return () => {
      cleanupSource()
      const v = videoRef.current
      if (v) {
        v.removeAttribute('src')
        v.load()
      }
    }
  }, [playerState.open, playerState.streamUrl, playerState.hlsUrl, playerState.sessionId, cleanupSource])

  // Helper: disable all text tracks on the video element.
  const disableAllTextTracks = useCallback(() => {
    const video = videoRef.current
    if (!video) return
    for (let i = 0; i < video.textTracks.length; i++) {
      video.textTracks[i].mode = 'disabled'
    }
  }, [])

  // When subtitleUrl becomes null (subs turned off), disable all text tracks
  useEffect(() => {
    if (playerState.open && !playerState.subtitleUrl) {
      disableAllTextTracks()
    }
  }, [playerState.open, playerState.subtitleUrl, disableAllTextTracks])

  // Force subtitle track to 'showing' — Chromium often ignores the `default` attribute
  const subtitleActiveRef = useRef(false)
  useEffect(() => {
    subtitleActiveRef.current = !!(playerState.open && playerState.subtitleUrl)
  }, [playerState.open, playerState.subtitleUrl])

   useEffect(() => {
     if (!playerState.open || !playerState.subtitleUrl) return

     const forceShowSubtitles = () => {
       if (!subtitleActiveRef.current) return
       const video = videoRef.current
       if (!video) return
       for (let i = 0; i < video.textTracks.length; i++) {
         if (video.textTracks[i].kind === 'subtitles') {
           console.log(`[Subtitle] Track ${i}: mode=${video.textTracks[i].mode}, cues=${video.textTracks[i].cues?.length || 0}`)
           video.textTracks[i].mode = 'showing'
         }
       }
     }

     const video = videoRef.current
     if (!video) return

     console.log(`[Subtitle] Loading URL: ${playerState.subtitleUrl}`)
     forceShowSubtitles()
     video.addEventListener('loadedmetadata', forceShowSubtitles)
     video.addEventListener('loadeddata', forceShowSubtitles)
     video.addEventListener('canplay', forceShowSubtitles)
     const interval = setInterval(forceShowSubtitles, 1000)

     return () => {
       video.removeEventListener('loadedmetadata', forceShowSubtitles)
       video.removeEventListener('loadeddata', forceShowSubtitles)
       video.removeEventListener('canplay', forceShowSubtitles)
       clearInterval(interval)
       disableAllTextTracks()
     }
   }, [playerState.open, playerState.subtitleUrl, subtitleVersion, disableAllTextTracks])

  // Inject dynamic <style> for ::cue
  useEffect(() => {
    const sizeObj = SUB_SIZES.find(s => s.id === subtitleSize) || SUB_SIZES[1]
    const styleObj = SUB_STYLES.find(s => s.id === subtitleStyle) || SUB_STYLES[0]

    const styleEl = document.createElement('style')
    styleEl.textContent = `.video-player-video::cue { font-size: ${sizeObj.em}; font-family: inherit; ${styleObj.css} }`
    document.head.appendChild(styleEl)

    return () => { document.head.removeChild(styleEl) }
  }, [subtitleSize, subtitleStyle])

  // --- requestAnimationFrame time polling ---
  // Absolute time = seekBase + video.currentTime
  const updateTime = useCallback(() => {
    if (seekBarDragging.current) return
    const video = videoRef.current
    if (video && !video.paused && isFinite(video.currentTime) && video.currentTime > 0) {
      setCurrentTime(seekBaseRef.current + video.currentTime)
    }
  }, [])

  useEffect(() => {
    if (!playerState.open) return

    const tick = () => {
      updateTime()
      rafRef.current = requestAnimationFrame(tick)
    }

    rafRef.current = requestAnimationFrame(tick)

    const video = videoRef.current
    if (video) video.addEventListener('timeupdate', updateTime)

    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current)
      if (video) video.removeEventListener('timeupdate', updateTime)
    }
  }, [playerState.open, updateTime])

  // Report progress periodically (absolute time)
  useEffect(() => {
    if (!playerState.open) return

    const timer = setInterval(() => {
      const video = videoRef.current
      if (video && !video.paused && isFinite(video.currentTime) && video.currentTime > 0) {
        api.reportProgress(seekBaseRef.current + video.currentTime, totalDuration, {
          type: playerState.type,
          episodeId: playerState.episodeId,
          movieId: playerState.movieId,
        })
      }
    }, 3000)

    return () => clearInterval(timer)
  }, [playerState.open, playerState.type, playerState.episodeId, playerState.movieId, totalDuration])

  // Show/hide controls on mouse activity
  const showControls = useCallback(() => {
    setControlsVisible(true)
    clearTimeout(hideTimerRef.current)
    hideTimerRef.current = setTimeout(() => {
      // Don't hide if paused, menu open, or in settings mode on TV
      if (!paused && !trackMenuOpen && (!isAndroidTV || tvMode === 'seek')) {
        setControlsVisible(false)
      }
    }, 3000)
  }, [paused, trackMenuOpen, isAndroidTV, tvMode])

  useEffect(() => {
    if (paused || trackMenuOpen) {
      setControlsVisible(true)
      clearTimeout(hideTimerRef.current)
    } else {
      showControls()
    }
  }, [paused, trackMenuOpen, showControls])

  // On Android TV, auto-focus play button when controls become visible
  useEffect(() => {
    if (isAndroidTV && controlsVisible && playBtnRef.current && !trackMenuOpen) {
      // Only focus if nothing else is focused
      const activeEl = document.activeElement
      const isVideoOrBody = !activeEl || activeEl === document.body || activeEl === videoRef.current
      if (isVideoOrBody) {
        playBtnRef.current.focus({ preventScroll: true })
      }
    }
  }, [controlsVisible, isAndroidTV, trackMenuOpen])

  // Close track menu when clicking outside
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

  // Fullscreen change listener (handles both standard and iOS fullscreen)
  useEffect(() => {
    const handler = () => {
      const video = videoRef.current
      const isStandardFullscreen = !!document.fullscreenElement
      const isIOSFullscreen = video && video.webkitDisplayingFullscreen
      setIsFullscreen(isStandardFullscreen || isIOSFullscreen)
    }
    document.addEventListener('fullscreenchange', handler)
    videoRef.current?.addEventListener('webkitbeginfullscreen', handler)
    videoRef.current?.addEventListener('webkitendfullscreen', handler)
    return () => {
      document.removeEventListener('fullscreenchange', handler)
      videoRef.current?.removeEventListener('webkitbeginfullscreen', handler)
      videoRef.current?.removeEventListener('webkitendfullscreen', handler)
    }
  }, [])

  // --- Callbacks ---

  const handleClose = useCallback(() => {
    const video = videoRef.current
    const absTime = video && isFinite(video.currentTime) ? seekBaseRef.current + video.currentTime : 0
    const dur = totalDuration
    if (document.fullscreenElement) {
      document.exitFullscreen()
    }
    // Exit iOS fullscreen if active
    if (video?.webkitDisplayingFullscreen) {
      video.webkitExitFullscreen?.()
    }
    closePlayer(absTime, dur)
  }, [closePlayer, totalDuration])

  const handleEnded = useCallback(() => {
    if (playerState.type === 'episode') {
      playNextEpisode()
    } else {
      handleClose()
    }
  }, [playerState.type, playNextEpisode, handleClose])

  // Seek: ask server to restart ffmpeg at target time, get new stream URL
  const seekingRef = useRef(false)

  const doSeek = useCallback(async (absoluteTime) => {
    if (seekingRef.current) return
    seekingRef.current = true

    try {
      setBuffering(true)
      disableAllTextTracks()

      const result = await seekPlayback(absoluteTime)
      if (result) {
        // seekPlayback updates playerState.hlsUrl + seekBase + sessionId,
        // which triggers the source useEffect to set up a new stream.
        seekBaseRef.current = result.seekBase ?? absoluteTime
        setCurrentTime(absoluteTime)
        setSubtitleVersion(v => v + 1)
      }
    } catch (err) {
      console.error('Seek failed:', err)
    } finally {
      seekingRef.current = false
    }
  }, [disableAllTextTracks, seekPlayback])

  const handleSeekRelative = useCallback((delta) => {
    const video = videoRef.current
    if (!video) return
    if (totalDuration <= 0) return

    const currentAbs = seekBaseRef.current + (isFinite(video.currentTime) ? video.currentTime : 0)
    const newTime = Math.max(0, Math.min(currentAbs + delta, totalDuration))

    doSeek(newTime)
  }, [totalDuration, doSeek])

  // Seek bar: drag updates visual position, commit triggers actual seek
  const seekBarDragging = useRef(false)
  const seekBarTarget = useRef(null)

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
    const video = videoRef.current
    if (!video) return

    const currentVideoTime = isFinite(video.currentTime) ? video.currentTime : 0

    setBuffering(true)
    const result = await switchAudio(audioStreamIndex, currentVideoTime)
    if (result && (result.streamUrl || result.hlsUrl)) {
      // switchAudio updates playerState.streamUrl/hlsUrl + seekBase + sessionId,
      // which triggers the source useEffect to set up a new stream.
      const resumeBase = result.seekBase ?? (seekBaseRef.current + currentVideoTime)
      seekBaseRef.current = resumeBase
      setCurrentTime(resumeBase)
      setSubtitleVersion(v => v + 1)
    } else {
      setBuffering(false)
    }
  }, [switchAudio])

  const handleSwitchSubtitle = useCallback(async (subtitleStreamIndex) => {
    disableAllTextTracks()
    await switchSubtitle(subtitleStreamIndex)
  }, [switchSubtitle, disableAllTextTracks])

  const handleSwitchBitmapSubtitle = useCallback(async (subtitleStreamIndex) => {
    const video = videoRef.current
    if (!video) return

    const currentVideoTime = isFinite(video.currentTime) ? video.currentTime : 0

    disableAllTextTracks()
    setBuffering(true)
    const result = await switchBitmapSubtitle(subtitleStreamIndex, currentVideoTime)
    if (result && (result.streamUrl || result.hlsUrl)) {
      // switchBitmapSubtitle updates playerState.streamUrl/hlsUrl + seekBase + sessionId,
      // which triggers the source useEffect to set up a new stream.
      const resumeBase = result.seekBase ?? (seekBaseRef.current + currentVideoTime)
      seekBaseRef.current = resumeBase
      setCurrentTime(resumeBase)
      setSubtitleVersion(v => v + 1)
    } else {
      setBuffering(false)
    }
  }, [switchBitmapSubtitle, disableAllTextTracks])

  const toggleFullscreen = useCallback(() => {
    const video = videoRef.current
    if (!video) return

    // Try to detect if we're on iOS
    const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)

    if (isIOS) {
      // On iOS, use webkitEnterFullscreen / webkitExitFullscreen
      if (video.webkitDisplayingFullscreen) {
        video.webkitExitFullscreen?.()
      } else {
        video.webkitEnterFullscreen?.()
      }
    } else {
      // On other platforms, use standard fullscreen API
      if (document.fullscreenElement) {
        document.exitFullscreen()
      } else if (containerRef.current) {
        containerRef.current.requestFullscreen?.()
      }
    }
  }, [])

  const handleVolumeChange = useCallback((e) => {
    const val = parseFloat(e.target.value)
    setVolume(val)
    if (videoRef.current) {
      videoRef.current.volume = val
      if (val > 0 && videoRef.current.muted) {
        videoRef.current.muted = false
      }
    }
  }, [])

  // --- Keyboard controls ---

  // Handle Android TV back button via Capacitor App plugin
  useEffect(() => {
    if (!playerState.open || !isAndroidTV) return
    
    const setupBackHandler = async () => {
      try {
        const { App } = await import('@capacitor/app')
        
        const backHandler = App.addListener('backButton', () => {
          console.log('[Player] Android TV back button pressed, tvMode:', tvMode)
          if (tvMode === 'audio' || tvMode === 'subtitles') {
            setTvMode('seek')
          } else if (trackMenuOpen) {
            setTrackMenuOpen(false)
          } else {
            handleClose()
          }
        })
        
        return () => {
          backHandler.then(h => h.remove())
        }
      } catch (err) {
        console.warn('[Player] Could not set up back handler:', err)
      }
    }
    
    const cleanup = setupBackHandler()
    return () => {
      cleanup?.then(fn => fn?.())
    }
  }, [playerState.open, isAndroidTV, trackMenuOpen, handleClose, tvMode])

  useEffect(() => {
    if (!playerState.open) return

    const handleKey = (e) => {
      const video = videoRef.current
      if (!video) return

      // Android TV has two modes: 'seek' and 'settings'
      // In seek mode: Left/Right = seek, Enter = play/pause, Up = go to settings
      // In settings mode: D-pad navigates menu, Back = return to seek mode
      
      if (isAndroidTV) {
        switch (e.key) {
          case 'Enter':
            e.preventDefault()
            if (tvMode === 'seek') {
              video.paused ? video.play() : video.pause()
            }
            // In settings mode, let browser handle button clicks
            break
          case 'Escape':
          case 'GoBack':
            e.preventDefault()
            if (tvMode === 'audio' || tvMode === 'subtitles') {
              setTvMode('seek')
            } else {
              handleClose()
            }
            break
          case 'ArrowLeft':
            if (tvMode === 'seek') {
              e.preventDefault()
              handleSeekRelative(-10)
              showControls()
            }
            // In settings mode, let browser handle D-pad
            break
          case 'ArrowRight':
            if (tvMode === 'seek') {
              e.preventDefault()
              handleSeekRelative(10)
              showControls()
            }
            // In settings mode, let browser handle D-pad
            break
          case 'ArrowUp':
            if (tvMode === 'seek') {
              e.preventDefault()
              setTvMode('audio')
            }
            // In settings mode, let browser handle D-pad for menu navigation (don't preventDefault)
            break
          case 'ArrowDown':
            if (tvMode === 'seek') {
              e.preventDefault()
              setTvMode('subtitles')
            }
            // In settings mode, let browser handle D-pad for menu navigation (don't preventDefault)
            break
          case 'MediaPlayPause':
          case 'MediaPlay':
          case 'MediaPause':
            e.preventDefault()
            video.paused ? video.play() : video.pause()
            break
          case 'MediaStop':
            e.preventDefault()
            handleClose()
            break
          case 'MediaRewind':
            e.preventDefault()
            handleSeekRelative(-30)
            break
          case 'MediaFastForward':
            e.preventDefault()
            handleSeekRelative(30)
            break
        }
        return
      }
      
      // Desktop controls (unchanged)
      switch (e.key) {
        case ' ':
        case 'k':
          e.preventDefault()
          video.paused ? video.play() : video.pause()
          break
        case 'Enter':
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
          showControls()
          break
        case 'ArrowRight':
          e.preventDefault()
          handleSeekRelative(10)
          showControls()
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
        case 'MediaPlayPause':
        case 'MediaPlay':
        case 'MediaPause':
          e.preventDefault()
          video.paused ? video.play() : video.pause()
          break
        case 'MediaStop':
          e.preventDefault()
          handleClose()
          break
        case 'MediaRewind':
          e.preventDefault()
          handleSeekRelative(-30)
          break
        case 'MediaFastForward':
          e.preventDefault()
          handleSeekRelative(30)
          break
      }
    }

    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [playerState.open, showControls, handleClose, toggleFullscreen, handleSeekRelative, trackMenuOpen, isAndroidTV, tvMode])

  if (!playerState.open) return null

  const progressPct = totalDuration > 0 ? (currentTime / totalDuration) * 100 : 0

  // Android TV: Simplified UI with two modes
  if (isAndroidTV) {
    // TV controls visibility state
    const tvControlsHidden = !controlsVisible && !paused && !buffering && tvMode === 'seek'
    const isSettingsMode = tvMode === 'audio' || tvMode === 'subtitles'
    
    return (
      <div
        ref={containerRef}
        className={`video-player-overlay controls-visible tv-player${isSettingsMode ? ' tv-settings-mode' : ''}`}
      >
        {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
        <video
          ref={videoRef}
          className="video-player-video"
          crossOrigin="anonymous"
          autoPlay
          playsInline
          muted={true}
          controls={false}
          onPlay={() => { console.log('[Video] play event'); setPaused(false) }}
          onPause={() => { console.log('[Video] pause event', new Error().stack); setPaused(true) }}
          onWaiting={() => { console.log('[Video] waiting event'); setBuffering(true) }}
          onStalled={() => console.log('[Video] stalled event')}
          onSuspend={() => console.log('[Video] suspend event')}
          onCanPlay={() => {
            setBuffering(false)
            const v = videoRef.current
            if (v && v.paused) v.play().catch(() => {})
            if (v && v.muted) v.muted = false
          }}
          onPlaying={() => {
            setBuffering(false)
            const v = videoRef.current
            if (v && v.muted) v.muted = false
          }}
          onEnded={handleEnded}
        >
          {playerState.subtitleUrl && (
            <track key={playerState.subtitleUrl + '-' + subtitleVersion} kind="subtitles" src={playerState.subtitleUrl + '&v=' + subtitleVersion} label="Subtitles" default crossOrigin="anonymous" />
          )}
        </video>

        {/* Top: Title info */}
        {!tvControlsHidden && (
          <div className="video-player-tv-top">
            <span className="video-player-bottom-title">{playerState.title}</span>
            {playerState.subtitle && (
              <span className="video-player-bottom-subtitle">{playerState.subtitle}</span>
            )}
          </div>
        )}

        {/* Center: Show pause icon or spinner only when paused/buffering */}
        {(paused || buffering) && (
          <div className="video-player-tv-center">
            {buffering ? (
              <div className="spinner" style={{ width: 48, height: 48 }} />
            ) : (
              <svg width="64" height="64" viewBox="0 0 24 24" fill="currentColor" opacity="0.9">
                <rect x="5" y="3" width="5" height="18" rx="1"/>
                <rect x="14" y="3" width="5" height="18" rx="1"/>
              </svg>
            )}
          </div>
        )}

        {/* TV Seek Mode: Show seek bar at bottom */}
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

        {/* TV Audio Settings (Up arrow) */}
        {tvMode === 'audio' && (
          <div className="video-player-tv-settings" onClick={(e) => e.stopPropagation()}>
            <div className="tv-settings-panel">
              <div className="track-popover-section">
                <div className="track-popover-heading">Audio</div>
                {playerState.audioStreams.length > 1 ? (
                  playerState.audioStreams.map((s, idx) => {
                    const handleSelect = () => {
                      if (s.index !== playerState.activeAudioIndex) {
                        handleSwitchAudio(s.index)
                      }
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
                          {s.index === playerState.activeAudioIndex ? '\u2713' : ''}
                        </span>
                        <span className="track-popover-label">{audioLabel(s)}</span>
                      </button>
                    )
                  })
                ) : (
                  <button tabIndex={0} autoFocus className="track-popover-item active" onClick={() => setTvMode('seek')} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); setTvMode('seek') } }}>
                    <span className="track-popover-check">{'\u2713'}</span>
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

        {/* TV Subtitles Settings (Down arrow) */}
        {tvMode === 'subtitles' && (
          <div className="video-player-tv-settings" onClick={(e) => e.stopPropagation()}>
            <div className="tv-settings-panel">
              {/* Column 1: Subtitles */}
              <div className="track-popover-section">
                <div className="track-popover-heading">Subtitles</div>
                {playerState.subtitleStreams.length > 0 ? (
                  <>
                    {(() => {
                      const handleOffSelect = () => {
                        if (playerState.activeSubtitleIndex != null) {
                          if (playerState.isBitmapSubtitle) {
                            handleSwitchBitmapSubtitle(null)
                          } else {
                            handleSwitchSubtitle(null)
                          }
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
                            {playerState.activeSubtitleIndex == null ? '\u2713' : ''}
                          </span>
                          <span className="track-popover-label">Off</span>
                        </button>
                      )
                    })()}
                    {playerState.subtitleStreams.map((s) => {
                      const handleSelect = () => {
                        if (s.isText) {
                          if (playerState.isBitmapSubtitle) {
                            handleSwitchBitmapSubtitle(null).then(() => {
                              handleSwitchSubtitle(s.index)
                            })
                          } else {
                            handleSwitchSubtitle(s.index)
                          }
                        } else {
                          if (s.index !== playerState.activeSubtitleIndex) {
                            handleSwitchBitmapSubtitle(s.index)
                          }
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
                            {s.index === playerState.activeSubtitleIndex ? '\u2713' : ''}
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
                    <span className="track-popover-check">{'\u2713'}</span>
                    <span className="track-popover-label">None Available</span>
                  </button>
                )}
              </div>

              {/* Column 2: Size - always show, disable if no text subtitles */}
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
                        {s.id === subtitleSize ? '\u2713' : ''}
                      </span>
                      <span className="track-popover-label">{s.label}</span>
                    </button>
                  )
                })}
              </div>

              {/* Column 3: Style - always show, disable if no text subtitles */}
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
                        {s.id === subtitleStyle ? '\u2713' : ''}
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

  // Desktop UI (unchanged)
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
         crossOrigin="anonymous"
         autoPlay
         playsInline
         muted={true}
         controls={false}
         style={{ WebkitPlaysinline: 'true' }}
         onTouchStart={(e) => {
           // Mark this as a touch event so onClick ignores it
           isTouchRef.current = true
           e.stopPropagation()
           showControls()
         }}
         onClick={(e) => {
           e.stopPropagation()
           // Ignore click if it came from a touch event
           if (isTouchRef.current) {
             isTouchRef.current = false
             return
           }
           
           showControls()
           if (trackMenuOpen) { setTrackMenuOpen(false); return }
           
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
         onPlay={() => { console.log('[Video] play event'); setPaused(false) }}
         onPause={() => { console.log('[Video] pause event', new Error().stack); setPaused(true) }}
         onWaiting={() => { console.log('[Video] waiting event'); setBuffering(true) }}
         onStalled={() => console.log('[Video] stalled event')}
         onSuspend={() => console.log('[Video] suspend event')}
         onCanPlay={() => {
          setBuffering(false)
          // Ensure playback starts — autoPlay may not fire with MSE
          const v = videoRef.current
          if (v && v.paused) v.play().catch(() => {})
          // Unmute after video can play (iOS requires muted for autoplay)
          if (v && v.muted) v.muted = false
        }}
        onPlaying={() => {
          setBuffering(false)
          // Unmute when playback starts
          const v = videoRef.current
          if (v && v.muted) v.muted = false
        }}
        onEnded={handleEnded}
      >
        {playerState.subtitleUrl && (
          <track key={playerState.subtitleUrl + '-' + subtitleVersion} kind="subtitles" src={playerState.subtitleUrl + '&v=' + subtitleVersion} label="Subtitles" default crossOrigin="anonymous" />
        )}
      </video>

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

      {/* Center playback controls: skip back, play/pause, skip forward */}
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

        {/* Utility group: single glass pill, right column */}
        <div className="video-player-track-menu-anchor" ref={trackMenuRef}>
          <refractive.div className="video-player-utilities" refraction={utilityPillGlass}>
            {/* Volume slider */}
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
            {/* Volume icon (mute toggle) */}
            <button className="video-player-util-icon video-player-volume-btn" tabIndex={0} onClick={() => {
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
              tabIndex={0}
              onClick={() => setTrackMenuOpen(v => !v)}
              title="Audio & Subtitles"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
              </svg>
            </button>
            {/* Fullscreen icon */}
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
               {/* Audio section */}
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

               {/* Subtitles section */}
               {playerState.subtitleStreams.length > 0 && (
                 <div className="track-popover-section">
                   <div className="track-popover-heading">Subtitles</div>
                   <button
                     tabIndex={0}
                     autoFocus={playerState.audioStreams.length <= 1}
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
                       tabIndex={0}
                       className={`track-popover-item${s.index === playerState.activeSubtitleIndex ? ' active' : ''}`}
                       onClick={() => {
                         if (s.isText) {
                           if (playerState.isBitmapSubtitle) {
                             handleSwitchBitmapSubtitle(null).then(() => {
                               handleSwitchSubtitle(s.index)
                             })
                           } else {
                             handleSwitchSubtitle(s.index)
                           }
                         } else {
                           if (s.index !== playerState.activeSubtitleIndex) {
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

               {/* Subtitle Size */}
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

               {/* Subtitle Appearance */}
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
