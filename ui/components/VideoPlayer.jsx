import { useRef, useState, useEffect, useCallback } from 'react'
import { refractive } from '@hashintel/refractive'
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

  // seekBase: the absolute time (in the source file) that corresponds to
  // video.currentTime === 0 in the current stream.  After a seek/restart,
  // ffmpeg starts from seekBase, so the video element's timeline resets to 0.
  // Absolute time = seekBase + video.currentTime.
  const seekBaseRef = useRef(0)
  const stallTimerRef = useRef(null)

  const [paused, setPaused] = useState(false)
  const [currentTime, setCurrentTime] = useState(0) // absolute time for display
  const [buffering, setBuffering] = useState(true)
  const [controlsVisible, setControlsVisible] = useState(true)
  const [volume, setVolume] = useState(1)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const [trackMenuOpen, setTrackMenuOpen] = useState(false)
  // Bumped on every seek/audio switch so the <track> element remounts
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
      seekBaseRef.current = playerState.seekBase ?? playerState.startTime ?? 0
      setCurrentTime(seekBaseRef.current)
      setPaused(false)
      setBuffering(true)
      setControlsVisible(true)
      setTrackMenuOpen(false)
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
  // For HTTP streams (web path), use MediaSource Extensions (MSE) to
  // feed fMP4 chunks to the browser.  This avoids Chrome's issues with
  // playing fragmented MP4 directly via <video src="http://...">.
  //
  // For stream:// (desktop/Electron), use direct src assignment.
  const mseRef = useRef(null)   // { mediaSource, sourceBuffer, abortController }

  const cleanupMse = useCallback(() => {
    const mse = mseRef.current
    if (!mse) return
    mseRef.current = null

    // 1. Abort the in-flight fetch first — this stops pumping data
    try { mse.abortController.abort() } catch {}

    // 2. Abort SourceBuffer (stops any pending appendBuffer/remove)
    try {
      if (mse.sourceBuffer && mse.mediaSource.readyState === 'open') {
        mse.sourceBuffer.abort()
      }
    } catch {}

    // 3. Revoke the blob URL (frees memory)
    if (mse.objectUrl) {
      URL.revokeObjectURL(mse.objectUrl)
    }

    // NOTE: Do NOT call mediaSource.endOfStream() here.
    // Calling endOfStream() before the demuxer has HAVE_METADATA causes
    // a Chrome DEMUXER_ERROR_COULD_NOT_OPEN.  Revoking the object URL
    // and aborting the fetch is sufficient for cleanup.
  }, [])

  useEffect(() => {
    if (!playerState.open || !playerState.streamUrl) return
    const video = videoRef.current
    if (!video) return

    const url = playerState.streamUrl
    const isHttpStream = url.startsWith('http://') || url.startsWith('https://')

    // Clean up any previous MSE session
    cleanupMse()

    if (isHttpStream && typeof MediaSource !== 'undefined' && MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028,mp4a.40.2"')) {
      // ── MSE path (web) ──────────────────────────────────────────
      const mediaSource = new MediaSource()
      const objectUrl = URL.createObjectURL(mediaSource)
      video.src = objectUrl

      const abortController = new AbortController()
      const mseState = { mediaSource, sourceBuffer: null, abortController, objectUrl }
      mseRef.current = mseState

      mediaSource.addEventListener('sourceopen', () => {
        // Guard: if we were cleaned up before sourceopen fired, bail out
        if (mseRef.current !== mseState) return

        let sourceBuffer
        try {
          sourceBuffer = mediaSource.addSourceBuffer('video/mp4; codecs="avc1.640028,mp4a.40.2"')
        } catch (e) {
          console.error('[MSE] addSourceBuffer failed:', e)
          // Fallback to direct src
          URL.revokeObjectURL(objectUrl)
          video.src = url
          video.load()
          video.play().catch(() => {})
          return
        }

        mseState.sourceBuffer = sourceBuffer

        const queue = []
        let streamDone = false
        let chunksAppended = 0

        // Trim played-back data so the buffer doesn't grow forever.
        // Keeps from (currentTime - 10s) forward.
        const trimBuffer = () => {
          try {
            if (sourceBuffer.buffered.length === 0 || sourceBuffer.updating) return false
            const bufStart = sourceBuffer.buffered.start(0)
            const vid = videoRef.current
            const playPos = vid && isFinite(vid.currentTime) ? vid.currentTime : 0
            const trimEnd = Math.max(bufStart, playPos - 10)
            if (trimEnd - bufStart > 1) {
              sourceBuffer.remove(bufStart, trimEnd)
              return true
            }
          } catch {}
          return false
        }

        // Safe endOfStream: only call if we actually appended data and
        // the demuxer has had a chance to initialize (buffered ranges exist).
        const safeEndOfStream = () => {
          if (mediaSource.readyState !== 'open') return
          if (sourceBuffer.updating) return
          if (chunksAppended === 0) return  // no data ever appended
          try {
            if (sourceBuffer.buffered.length > 0) {
              mediaSource.endOfStream()
            }
          } catch {}
        }

        const flushQueue = () => {
          if (queue.length > 0 && !sourceBuffer.updating) {
            try {
              sourceBuffer.appendBuffer(queue.shift())
              chunksAppended++
            } catch (e) {
              if (e.name === 'QuotaExceededError') {
                console.warn('[MSE] QuotaExceededError, dropping queued chunks')
                queue.length = 0
              } else {
                console.error('[MSE] appendBuffer error:', e)
              }
            }
          } else if (streamDone && queue.length === 0 && !sourceBuffer.updating) {
            safeEndOfStream()
          }
        }

        sourceBuffer.addEventListener('updateend', () => {
          if (trimBuffer()) return
          flushQueue()
        })

        const appendChunk = (chunk) => {
          if (sourceBuffer.updating || queue.length > 0) {
            queue.push(chunk)
          } else {
            try {
              sourceBuffer.appendBuffer(chunk)
              chunksAppended++
            } catch (e) {
              if (e.name === 'QuotaExceededError') {
                console.warn('[MSE] QuotaExceededError, dropping chunk')
              } else {
                console.error('[MSE] appendBuffer error:', e)
              }
            }
          }
        }

        // Fetch the stream and pipe chunks into SourceBuffer.
        fetch(url, { signal: abortController.signal })
          .then(response => {
            if (!response.ok) {
              console.error('[MSE] Stream fetch failed:', response.status, response.statusText)
              return
            }
            const reader = response.body.getReader()
            const pump = () => {
              reader.read().then(({ done, value }) => {
                if (done) {
                  streamDone = true
                  safeEndOfStream()
                  return
                }
                appendChunk(value)
                pump()
              }).catch(() => {
                // fetch aborted or network error — normal during seek/close
              })
            }
            pump()
          })
          .catch(() => {
            // fetch aborted — normal during seek/close
          })

        // Don't call video.play() here — wait for data to arrive.
        // The <video autoPlay> attribute + canplay event will handle it.
      }, { once: true })
    } else {
      // ── Direct src path (desktop / fallback) ────────────────────
      video.src = url
      video.load()
      video.play().catch(() => {})
    }

    return () => {
      cleanupMse()
    }
  }, [playerState.open, playerState.streamUrl, playerState.sessionId, cleanupMse])

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
          video.textTracks[i].mode = 'showing'
        }
      }
    }

    const video = videoRef.current
    if (!video) return

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
        api.reportProgress(seekBaseRef.current + video.currentTime, totalDuration)
      }
    }, 3000)

    return () => clearInterval(timer)
  }, [playerState.open, totalDuration])

  // Stall detection: if buffering persists for 10s without recovery,
  // automatically re-seek to the current position to restart the
  // ffmpeg → MSE pipeline.  This handles cases where ffmpeg dies
  // silently or the SourceBuffer enters an unrecoverable state.
  // We use doSeekRef to avoid a dependency cycle (doSeek → setBuffering
  // → buffering → this effect → doSeek).
  const doSeekRef = useRef(null)

  const triggerRecovery = useCallback(() => {
    const video = videoRef.current
    if (!video) return
    const absTime = seekBaseRef.current + (isFinite(video.currentTime) ? video.currentTime : 0)
    console.warn(`Auto-recovering playback at ${absTime.toFixed(1)}s`)
    seekingRef.current = false
    if (doSeekRef.current) doSeekRef.current(absTime)
  }, [])

  // On video error: log it. The stall detection timer will handle recovery
  // if the video remains in buffering state.  Don't eagerly recover here —
  // calling cleanupMse + re-seek in a tight loop causes the
  // "endOfStream before HAVE_METADATA" cascade.
  useEffect(() => {
    if (!playerState.open) return
    const video = videoRef.current
    if (!video) return

    const onError = () => {
      console.warn('[MSE] Video element error:', video.error?.message)
    }

    video.addEventListener('error', onError)
    return () => video.removeEventListener('error', onError)
  }, [playerState.open, playerState.sessionId])

  useEffect(() => {
    if (!playerState.open) return

    if (buffering && !paused) {
      stallTimerRef.current = setTimeout(triggerRecovery, 10000)
    } else {
      clearTimeout(stallTimerRef.current)
      stallTimerRef.current = null
    }

    return () => {
      clearTimeout(stallTimerRef.current)
      stallTimerRef.current = null
    }
  }, [buffering, paused, playerState.open, triggerRecovery])

  // Show/hide controls on mouse activity
  const showControls = useCallback(() => {
    setControlsVisible(true)
    clearTimeout(hideTimerRef.current)
    hideTimerRef.current = setTimeout(() => {
      if (!paused && !trackMenuOpen) setControlsVisible(false)
    }, 3000)
  }, [paused, trackMenuOpen])

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
    const absTime = video && isFinite(video.currentTime) ? seekBaseRef.current + video.currentTime : 0
    const dur = totalDuration
    if (document.fullscreenElement) {
      document.exitFullscreen()
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
        // seekPlayback updates playerState.streamUrl + seekBase + sessionId,
        // which triggers the MSE useEffect to set up a new stream.
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
  doSeekRef.current = doSeek

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
    if (result && result.streamUrl) {
      // switchAudio updates playerState.streamUrl + seekBase + sessionId,
      // which triggers the MSE useEffect to set up a new stream.
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
    if (result && result.streamUrl) {
      // switchBitmapSubtitle updates playerState.streamUrl + seekBase + sessionId,
      // which triggers the MSE useEffect to set up a new stream.
      const resumeBase = result.seekBase ?? (seekBaseRef.current + currentVideoTime)
      seekBaseRef.current = resumeBase
      setCurrentTime(resumeBase)
      setSubtitleVersion(v => v + 1)
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
        crossOrigin="anonymous"
        autoPlay
        onClick={(e) => {
          e.stopPropagation()
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
        onPlay={() => setPaused(false)}
        onPause={() => setPaused(true)}
        onWaiting={() => setBuffering(true)}
        onCanPlay={() => {
          setBuffering(false)
          // Ensure playback starts — autoPlay may not fire with MSE
          const v = videoRef.current
          if (v && v.paused) v.play().catch(() => {})
        }}
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

              {/* Subtitles section */}
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
                            if (playerState.isBitmapSubtitle) {
                              handleSwitchBitmapSubtitle(null).then(() => {
                                handleSwitchSubtitle(s.index)
                              })
                            } else {
                              handleSwitchSubtitle(s.index)
                            }
                          } else {
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
