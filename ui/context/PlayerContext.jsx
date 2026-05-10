import { createContext, useContext, useState, useCallback, useEffect, useMemo, useRef } from 'react'
import { flushSync } from 'react-dom'
import { useToast } from './ToastContext'
import { useApi, useCapabilities } from './ApiContext'

const PlayerContext = createContext(null)

// PlayerContext serves two playback engines:
//
//   1. HTML5 <video> + HLS.js (web/, android-tv/, hybrid-remote on desktop).
//      State carriers: streamUrl/hlsUrl + seekBase + sessionId. Each seek
//      or audio-switch restarts the server transcoder; the renderer reloads
//      the <video> source.
//
//   2. Embedded libVLC (desktop/local + hybrid-local), driven by the native
//      vlc-embed module that renders into the BrowserWindow's NSView.
//      State comes from periodic 'playback:state' IPC pushes; seek/track
//      switches are property sets — no URL change.
//
// Both modes write into the same PlayerContext shape so consumers
// (NowPlayingBar, VideoPlayer, VlcOverlay) read state uniformly.
export function PlayerProvider({ children }) {
  const { showToast } = useToast()
  const api = useApi()
  const capabilities = useCapabilities()
  const usingVlc = !!capabilities?.hasVlcEmbedPlayer
  const [launching, setLaunching] = useState(false)
  const [playerState, setPlayerState] = useState({
    open: false,
    streamUrl: null,
    hlsUrl: null,
    subtitleUrl: null,
    duration: 0,
    startTime: 0,
    seekBase: 0,
    title: '',
    subtitle: '',
    type: null,
    episodeId: null,
    watchHistoryId: null,
    showId: null,
    movieId: null,
    sessionId: 0,
    audioStreams: [],
    subtitleStreams: [],
    activeAudioIndex: null,
    activeSubtitleIndex: null,
    isBitmapSubtitle: false,
    strategy: null,
    video: null,
    bitrate: null,
    subtitleSize: 'medium',
    subtitleStyle: 'classic',
    // Engine-pushed state (libVLC mode only).
    currentTime: 0,
    paused: false,
    eof: false,
  })

  const stateRef = useRef(playerState)
  useEffect(() => { stateRef.current = playerState }, [playerState])

  const openPlayer = useCallback(async ({ type, episodeId, showId, movieId, title, subtitle, filePath, startTime }) => {
    setLaunching(true)

    // libVLC mode: apply the body-level transparency synchronously so the
    // window goes see-through on the same frame the user clicked Play.
    // Doing this in VlcOverlay's useEffect lagged a frame behind the React
    // re-render, leaving a flash of the opaque browse UI.
    if (usingVlc && typeof document !== 'undefined') {
      document.body.classList.add('vlc-playing')
    }

    // Optimistic open: set playerState.open = true immediately so the
    // overlay mounts and renders the loading curtain in parallel with the
    // long IPC startPlayback call.
    setPlayerState(prev => ({
      ...prev,
      open: true,
      title: title || '',
      subtitle: subtitle || '',
      type,
      episodeId: type === 'episode' ? episodeId?.id : null,
      watchHistoryId: type === 'episode' ? (episodeId?.whId || null) : null,
      showId: type === 'episode' ? (showId || null) : null,
      movieId: type === 'movie' ? movieId : null,
      startTime: startTime || 0,
      currentTime: startTime || 0,
      paused: false,
      eof: false,
      engineReady: false,
      audioStreams: [],
      subtitleStreams: [],
    }))

    try {
      if (type === 'episode') {
        await api.setPlaybackEpisode(episodeId.id, episodeId.whId)
      } else if (type === 'movie') {
        await api.setPlaybackMovie(movieId)
      }

      let prefs = null
      try {
        const prefPromise = api.getPlaybackPreferences({
          type,
          showId: type === 'episode' ? (showId || null) : null,
          movieId: type === 'movie' ? movieId : null,
        })
        const timeout = new Promise(resolve => setTimeout(() => resolve(null), 1000))
        prefs = await Promise.race([prefPromise, timeout])
      } catch {}

      const result = await api.startPlayback(filePath, startTime || 0, prefs)
      if (result.error) {
        console.error('Failed to start playback:', result.error)
        showToast(result.error, { type: 'error', duration: 6000 })
        if (typeof document !== 'undefined') {
          document.body.classList.remove('vlc-playing')
          document.body.classList.remove('vlc-ready')
        }
        setPlayerState(prev => ({ ...prev, open: false }))
        setLaunching(false)
        return
      }

      // Hybrid mode advertises hasVlcEmbedPlayer (inherits from local), but
      // when the file isn't reachable locally the server streams HLS instead.
      // libvlc never runs, so engineReady never flips, so vlc-ready never
      // gets added and body.vlc-playing's curtain hides #root forever — the
      // HLS player below stays invisible while hls.js storms the server.
      //
      // Mount WebVideoPlayer (its black overlay covers #root) BEFORE pulling
      // the curtain off — otherwise there's a paint frame where the curtain
      // is gone but WebVideoPlayer hasn't mounted, and the transparent
      // BrowserWindow flashes through whatever route was underneath.
      // flushSync forces React to commit the state update synchronously so
      // the DOM has WebVideoPlayer in place when we strip the curtain class.
      const isHls = !!(result.streamUrl || result.hlsUrl)

      flushSync(() => {
        setPlayerState({
          open: true,
          streamUrl: result.streamUrl ?? null,
          hlsUrl: result.hlsUrl ?? null,
          subtitleUrl: result.subtitleUrl ?? null,
          duration: result.duration,
          startTime: startTime || 0,
          seekBase: result.seekBase ?? startTime ?? 0,
          title: title || '',
          subtitle: subtitle || '',
          type,
          episodeId: type === 'episode' ? episodeId?.id : null,
          watchHistoryId: type === 'episode' ? (episodeId?.whId || null) : null,
          showId: type === 'episode' ? (showId || null) : null,
          movieId: type === 'movie' ? movieId : null,
          sessionId: Date.now(),
          audioStreams: result.audioStreams || [],
          subtitleStreams: result.subtitleStreams || [],
          activeAudioIndex: result.activeAudioIndex ?? null,
          activeSubtitleIndex: result.activeSubtitleIndex ?? null,
          isBitmapSubtitle: result.isBitmapSubtitle || false,
          strategy: result.strategy || null,
          video: result.video || null,
          bitrate: result.bitrate || null,
          subtitleSize: prefs?.subtitleSize || 'medium',
          subtitleStyle: prefs?.subtitleStyle || 'classic',
          currentTime: startTime || 0,
          paused: false,
          eof: false,
        })
      })

      if (isHls && typeof document !== 'undefined') {
        document.body.classList.remove('vlc-playing')
        document.body.classList.remove('vlc-ready')
      }
    } catch (err) {
      console.error('openPlayer error:', err)
      showToast('Playback failed: ' + (err.message || 'Unknown error'), { type: 'error' })
      if (typeof document !== 'undefined') {
        document.body.classList.remove('vlc-playing')
        document.body.classList.remove('vlc-ready')
      }
      setPlayerState(prev => ({ ...prev, open: false }))
    } finally {
      setLaunching(false)
    }
  }, [showToast, api])

  const closePlayer = useCallback((finalTime, finalDuration) => {
    let context = {}
    setPlayerState(prev => {
      context = { type: prev.type, episodeId: prev.episodeId, movieId: prev.movieId }
      return {
        ...prev,
        open: false,
        streamUrl: null,
        hlsUrl: null,
        currentTime: 0,
        paused: false,
        eof: false,
        engineReady: false,
      }
    })
    if (typeof document !== 'undefined') {
      document.body.classList.remove('vlc-playing')
      document.body.classList.remove('vlc-ready')
    }
    window.dispatchEvent(new Event('playback-stopped'))
    api.stopPlayback(finalTime, finalDuration, context).catch(() => {})
  }, [api])

  const playNextEpisode = useCallback(async () => {
    let currentEpisodeId = null
    setPlayerState(prev => { currentEpisodeId = prev.episodeId; return prev })
    if (!currentEpisodeId) { closePlayer(); return }
    try {
      const nextData = await api.getNextEpisode(currentEpisodeId)
      if (!nextData || !nextData.episode) { closePlayer(); return }
      const nextEp = nextData.episode
      await api.stopPlayback().catch(() => {})
      const result = await api.playEpisode(nextEp.id)
      if (!result || result.error) { closePlayer(); return }
      await openPlayer({
        type: 'episode',
        episodeId: { id: result.episode_id, whId: result.watch_history_id },
        showId: result.show_id,
        filePath: result.file_path,
        startTime: result.start_time,
        title: nextData.show_name || '',
        subtitle: nextEp.code + ' — ' + (nextEp.title || ''),
      })
    } catch (err) {
      console.error('playNextEpisode error:', err)
      showToast('Failed to play next episode: ' + (err.message || 'Unknown error'), { type: 'error' })
      closePlayer()
    }
  }, [closePlayer, openPlayer, showToast, api])

  const savePreferences = useCallback((state, overrides = {}) => {
    const audioId = overrides.activeAudioIndex ?? state.activeAudioIndex
    const subtitleId = overrides.activeSubtitleIndex !== undefined ? overrides.activeSubtitleIndex : state.activeSubtitleIndex
    const audioStream = state.audioStreams.find(s => (s.id ?? s.index) === audioId)
    const subtitleStream = subtitleId != null ? state.subtitleStreams.find(s => (s.id ?? s.index) === subtitleId) : null

    api.savePlaybackPreferences({
      type: state.type,
      showId: state.showId,
      movieId: state.movieId,
      audioLanguage: audioStream?.language || null,
      audioCodec: audioStream?.codec || null,
      audioChannels: audioStream?.channels || null,
      subtitleLanguage: subtitleStream?.language || null,
      subtitleOff: subtitleId == null,
      subtitleSize: overrides.subtitleSize || state.subtitleSize || 'medium',
      subtitleStyle: overrides.subtitleStyle || state.subtitleStyle || 'classic',
    }).catch(() => {})
  }, [api])

  const seekPlayback = useCallback(async (absoluteTime) => {
    try {
      const result = await api.seekPlayback(absoluteTime)
      if (!result) return null
      setPlayerState(prev => {
        const next = { ...prev }
        if (result.streamUrl != null) next.streamUrl = result.streamUrl
        if (result.hlsUrl != null) next.hlsUrl = result.hlsUrl
        if (result.streamUrl || result.hlsUrl) {
          next.seekBase = result.seekBase ?? absoluteTime
          next.sessionId = Date.now()
          if (prev.subtitleUrl) {
            const base = prev.subtitleUrl.replace(/&t=\d+/, '')
            next.subtitleUrl = `${base}&t=${Date.now()}`
          }
          if (result.strategy) next.strategy = result.strategy
        } else {
          next.currentTime = absoluteTime
        }
        return next
      })
      return result
    } catch (err) {
      console.error('seekPlayback error:', err)
    }
    return null
  }, [api])

  const switchAudio = useCallback(async (audioStreamId, currentVideoTime) => {
    try {
      const result = await api.switchAudio(audioStreamId, currentVideoTime)
      if (!result) return null
      setPlayerState(prev => {
        const next = { ...prev, activeAudioIndex: audioStreamId }
        if (result.streamUrl != null) {
          next.streamUrl = result.streamUrl
          next.seekBase = result.seekBase ?? (prev.seekBase + (currentVideoTime || 0))
          next.sessionId = Date.now()
          if (prev.subtitleUrl) {
            const base = prev.subtitleUrl.replace(/&t=\d+/, '')
            next.subtitleUrl = `${base}&t=${Date.now()}`
          }
          if (result.hlsUrl != null) next.hlsUrl = result.hlsUrl
          if (result.strategy) next.strategy = result.strategy
        }
        savePreferences(next)
        return next
      })
      return result
    } catch (err) {
      console.error('switchAudio error:', err)
    }
    return null
  }, [savePreferences, api])

  const switchSubtitle = useCallback(async (subtitleStreamId) => {
    try {
      const result = await api.switchSubtitle(subtitleStreamId)
      if (!result) return null
      if (result.error) console.warn('[Subtitle] switchSubtitle error:', result.error)
      setPlayerState(prev => {
        const next = { ...prev, activeSubtitleIndex: subtitleStreamId }
        if ('subtitleUrl' in result) {
          next.subtitleUrl = result.subtitleUrl
          next.isBitmapSubtitle = false
        }
        savePreferences(next, { activeSubtitleIndex: subtitleStreamId })
        return next
      })
      return result
    } catch (err) {
      console.error('switchSubtitle error:', err)
    }
    return null
  }, [savePreferences, api])

  // HLS-only legacy method for the web/android <video>+ffmpeg path.
  const switchBitmapSubtitle = useCallback(async (subtitleStreamIndex, currentVideoTime) => {
    try {
      const result = await api.switchBitmapSubtitle?.(subtitleStreamIndex, currentVideoTime)
      if (result && (result.streamUrl || result.hlsUrl)) {
        setPlayerState(prev => {
          const isBitmap = subtitleStreamIndex != null
          const next = {
            ...prev,
            streamUrl: result.streamUrl ?? prev.streamUrl,
            hlsUrl: result.hlsUrl ?? prev.hlsUrl,
            seekBase: result.seekBase ?? (prev.seekBase + (currentVideoTime || 0)),
            activeSubtitleIndex: subtitleStreamIndex,
            isBitmapSubtitle: isBitmap,
            subtitleUrl: null,
            sessionId: Date.now(),
            strategy: result.strategy ?? prev.strategy,
          }
          savePreferences(next, { activeSubtitleIndex: subtitleStreamIndex })
          return next
        })
        return result
      }
    } catch (err) {
      console.error('switchBitmapSubtitle error:', err)
    }
    return null
  }, [savePreferences, api])

  const setSubtitleAppearance = useCallback(({ subtitleSize, subtitleStyle }) => {
    setPlayerState(prev => {
      const next = { ...prev }
      if (subtitleSize !== undefined) next.subtitleSize = subtitleSize
      if (subtitleStyle !== undefined) next.subtitleStyle = subtitleStyle
      savePreferences(next, { subtitleSize: next.subtitleSize, subtitleStyle: next.subtitleStyle })
      return next
    })
    if (usingVlc && api.setSubtitleAppearance) {
      api.setSubtitleAppearance({ size: subtitleSize, style: subtitleStyle }).catch(() => {})
    }
  }, [savePreferences, api, usingVlc])

  // Toggle the body.vlc-ready class so the CSS-pseudo-element curtain
  // disappears the instant libvlc reports its first frame.
  useEffect(() => {
    if (typeof document === 'undefined') return
    if (playerState.open && playerState.engineReady) {
      document.body.classList.add('vlc-ready')
    } else {
      document.body.classList.remove('vlc-ready')
    }
  }, [playerState.open, playerState.engineReady])

  // libVLC mode: subscribe to live state pushes.
  useEffect(() => {
    if (!usingVlc || !api.onPlaybackState) return
    const unsub = api.onPlaybackState(state => {
      setPlayerState(prev => {
        if (!prev.open) return prev
        // engineReady flips on the first push past the requested startTime
        // — that's the "first frame decoded" signal for the curtain.
        const engineReady = prev.engineReady ||
          (state.time != null && state.time > (prev.startTime || 0) - 0.5)
        return {
          ...prev,
          currentTime: state.time ?? prev.currentTime,
          paused: state.paused ?? prev.paused,
          duration: state.duration || prev.duration,
          eof: !!state.ended,
          engineReady,
        }
      })
    })
    return unsub
  }, [usingVlc, api])

  useEffect(() => {
    if (!usingVlc || !api.onPlaybackTracks) return
    const unsub = api.onPlaybackTracks(tracks => {
      setPlayerState(prev => {
        if (!prev.open) return prev
        const audio = tracks.audio || []
        const subtitle = tracks.subtitle || []
        return {
          ...prev,
          audioStreams: audio.length ? audio : prev.audioStreams,
          subtitleStreams: subtitle.length ? subtitle : prev.subtitleStreams,
        }
      })
    })
    return unsub
  }, [usingVlc, api])

  useEffect(() => {
    if (!usingVlc || !api.onPlaybackEnded) return
    const unsub = api.onPlaybackEnded(() => {
      const cur = stateRef.current
      if (cur.type === 'episode') playNextEpisode()
      else closePlayer(cur.currentTime, cur.duration)
    })
    return unsub
  }, [usingVlc, api, playNextEpisode, closePlayer])

  const contextValue = useMemo(() => ({
    playerState, launching, openPlayer, closePlayer, playNextEpisode,
    seekPlayback, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance,
  }), [playerState, launching, openPlayer, closePlayer, playNextEpisode, seekPlayback, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance])

  return (
    <PlayerContext.Provider value={contextValue}>
      {children}
    </PlayerContext.Provider>
  )
}

export function usePlayer() {
  const ctx = useContext(PlayerContext)
  if (!ctx) throw new Error('usePlayer must be used within PlayerProvider')
  return ctx
}
