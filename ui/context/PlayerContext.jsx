import { createContext, useContext, useState, useCallback, useEffect, useMemo, useRef } from 'react'
import { flushSync } from 'react-dom'
import { useToast } from './ToastContext'
import { useApi } from './ApiContext'

const PlayerContext = createContext(null)

// PlayerContext drives a single playback engine: the Jellyfin Player JS
// runtime (HTML5 <video> + hls.js + Safari native HLS) instantiated inside
// VideoPlayer.jsx. Track/seek/subtitle changes go through the engine: every
// audio or subtitle switch re-issues `api.startPlayback` to get a fresh
// HLS master URL with the requested track baked into the transcode token.
// Seek is purely local — hls.js + engine's seek-on-restart handle it.
export function PlayerProvider({ children }) {
  const { showToast } = useToast()
  const api = useApi()
  const [launching, setLaunching] = useState(false)
  const [playerState, setPlayerState] = useState({
    open: false,
    filePath: null,
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
    currentTime: 0,
    paused: false,
    eof: false,
  })

  const stateRef = useRef(playerState)
  useEffect(() => { stateRef.current = playerState }, [playerState])

  const openPlayer = useCallback(async ({ type, episodeId, showId, movieId, title, subtitle, filePath, startTime }) => {
    setLaunching(true)

    setPlayerState(prev => ({
      ...prev,
      open: true,
      filePath: filePath || null,
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
        setPlayerState(prev => ({ ...prev, open: false }))
        setLaunching(false)
        return
      }

      flushSync(() => {
        setPlayerState({
          open: true,
          filePath: filePath || null,
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
    } catch (err) {
      console.error('openPlayer error:', err)
      showToast('Playback failed: ' + (err.message || 'Unknown error'), { type: 'error' })
      setPlayerState(prev => ({ ...prev, open: false }))
    } finally {
      setLaunching(false)
    }
  }, [showToast, api])

  const closePlayer = useCallback((finalTime, finalDuration) => {
    let context = {}
    let sessionId = null
    setPlayerState(prev => {
      context = { type: prev.type, episodeId: prev.episodeId, movieId: prev.movieId }
      sessionId = prev.sessionId
      return {
        ...prev,
        open: false,
        streamUrl: null,
        hlsUrl: null,
        currentTime: 0,
        paused: false,
        eof: false,
      }
    })
    window.dispatchEvent(new Event('playback-stopped'))
    api.stopPlayback(finalTime, finalDuration, { ...context, sessionId }).catch(() => {})
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

  // Re-issue startPlayback with a new prefs payload so the engine signs a
  // fresh transcode token with the new track baked in. Caller passes the
  // current absolute playback time so we resume at the same spot.
  const relaunchWithPrefs = useCallback(async (prefsOverride, absoluteResumeTime) => {
    const cur = stateRef.current
    if (!cur.filePath) return null

    const prefs = {
      audioLanguage: prefsOverride.audioLanguage ?? null,
      audioCodec: prefsOverride.audioCodec ?? null,
      audioChannels: prefsOverride.audioChannels ?? null,
      subtitleLanguage: prefsOverride.subtitleLanguage ?? null,
      subtitleOff: !!prefsOverride.subtitleOff,
      subtitleSize: prefsOverride.subtitleSize ?? cur.subtitleSize ?? 'medium',
      subtitleStyle: prefsOverride.subtitleStyle ?? cur.subtitleStyle ?? 'classic',
    }

    try {
      const result = await api.startPlayback(cur.filePath, absoluteResumeTime || 0, prefs)
      if (!result || result.error) return null

      setPlayerState(prev => ({
        ...prev,
        streamUrl: result.streamUrl ?? null,
        hlsUrl: result.hlsUrl ?? null,
        subtitleUrl: result.subtitleUrl ?? null,
        seekBase: result.seekBase ?? absoluteResumeTime ?? 0,
        startTime: absoluteResumeTime || 0,
        sessionId: Date.now(),
        audioStreams: result.audioStreams || prev.audioStreams,
        subtitleStreams: result.subtitleStreams || prev.subtitleStreams,
        activeAudioIndex: result.activeAudioIndex ?? prev.activeAudioIndex,
        activeSubtitleIndex: result.activeSubtitleIndex ?? prev.activeSubtitleIndex,
        isBitmapSubtitle: !!result.isBitmapSubtitle,
        strategy: result.strategy || prev.strategy,
      }))
      return result
    } catch (err) {
      console.error('relaunchWithPrefs error:', err)
      return null
    }
  }, [api])

  const switchAudio = useCallback(async (audioStreamId, currentVideoTime) => {
    const cur = stateRef.current
    const audioStream = cur.audioStreams.find(s => (s.id ?? s.index) === audioStreamId)
    if (!audioStream) return null

    const absoluteResume = (cur.seekBase || 0) + (currentVideoTime || 0)
    const result = await relaunchWithPrefs({
      audioLanguage: audioStream.language,
      audioCodec: audioStream.codec,
      audioChannels: audioStream.channels,
      subtitleLanguage: cur.subtitleStreams.find(s => s.index === cur.activeSubtitleIndex)?.language,
      subtitleOff: cur.activeSubtitleIndex == null,
    }, absoluteResume)

    if (result) {
      savePreferences(stateRef.current, { activeAudioIndex: audioStreamId })
    }
    return result
  }, [relaunchWithPrefs, savePreferences])

  // Player JS handles audio track switching natively only when the HLS master
  // advertises multiple audio renditions. Until the engine produces those, we
  // route every audio change through relaunchWithPrefs. This callback exists
  // so VideoPlayer can mark the index optimistically.
  const applyDirectPlayAudio = useCallback((audioStreamId) => {
    setPlayerState(prev => {
      const next = { ...prev, activeAudioIndex: audioStreamId }
      savePreferences(next)
      return next
    })
  }, [savePreferences])

  const switchSubtitle = useCallback(async (subtitleStreamId) => {
    const cur = stateRef.current
    const subtitleStream = subtitleStreamId != null
      ? cur.subtitleStreams.find(s => (s.id ?? s.index) === subtitleStreamId)
      : null
    const audioStream = cur.audioStreams.find(s => (s.id ?? s.index) === cur.activeAudioIndex)

    const result = await relaunchWithPrefs({
      audioLanguage: audioStream?.language,
      audioCodec: audioStream?.codec,
      audioChannels: audioStream?.channels,
      subtitleLanguage: subtitleStream?.language,
      subtitleOff: subtitleStream == null,
    }, (cur.seekBase || 0) + 0)

    if (result) {
      savePreferences(stateRef.current, { activeSubtitleIndex: subtitleStreamId })
    }
    return result
  }, [relaunchWithPrefs, savePreferences])

  const switchBitmapSubtitle = useCallback(async (subtitleStreamIndex, currentVideoTime) => {
    const cur = stateRef.current
    const subtitleStream = subtitleStreamIndex != null
      ? cur.subtitleStreams.find(s => (s.id ?? s.index) === subtitleStreamIndex)
      : null
    const audioStream = cur.audioStreams.find(s => (s.id ?? s.index) === cur.activeAudioIndex)

    const absoluteResume = (cur.seekBase || 0) + (currentVideoTime || 0)
    const result = await relaunchWithPrefs({
      audioLanguage: audioStream?.language,
      audioCodec: audioStream?.codec,
      audioChannels: audioStream?.channels,
      subtitleLanguage: subtitleStream?.language,
      subtitleOff: subtitleStream == null,
    }, absoluteResume)

    if (result) {
      savePreferences(stateRef.current, { activeSubtitleIndex: subtitleStreamIndex })
    }
    return result
  }, [relaunchWithPrefs, savePreferences])

  // Pure local-state update: VideoPlayer drives player.seek() directly.
  // Kept on the context for parity with the previous API; returns null so
  // existing callers (which `await` the result) don't break.
  const seekPlayback = useCallback(async (absoluteTime) => {
    setPlayerState(prev => ({ ...prev, currentTime: absoluteTime }))
    return null
  }, [])

  const setSubtitleAppearance = useCallback(({ subtitleSize, subtitleStyle }) => {
    setPlayerState(prev => {
      const next = { ...prev }
      if (subtitleSize !== undefined) next.subtitleSize = subtitleSize
      if (subtitleStyle !== undefined) next.subtitleStyle = subtitleStyle
      savePreferences(next, { subtitleSize: next.subtitleSize, subtitleStyle: next.subtitleStyle })
      return next
    })
  }, [savePreferences])

  const contextValue = useMemo(() => ({
    playerState, launching, openPlayer, closePlayer, playNextEpisode,
    seekPlayback, switchAudio, applyDirectPlayAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance,
  }), [playerState, launching, openPlayer, closePlayer, playNextEpisode, seekPlayback, switchAudio, applyDirectPlayAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance])

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
