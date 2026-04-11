import { createContext, useContext, useState, useCallback, useEffect, useMemo } from 'react'
import { useToast } from './ToastContext'
import { useApi } from './ApiContext'

const PlayerContext = createContext(null)

export function PlayerProvider({ children }) {
  const { showToast } = useToast()
  const api = useApi()
  const [launching, setLaunching] = useState(false)
  const [playerState, setPlayerState] = useState({
    open: false,
    streamUrl: null,
    subtitleUrl: null,
    duration: 0,
    startTime: 0,
    seekBase: 0,
    title: '',
    subtitle: '',
    type: null, // 'episode' | 'movie'
    episodeId: null,
    seriesId: null,
    movieId: null,
    sessionId: 0,
    audioStreams: [],
    subtitleStreams: [],
    activeAudioIndex: null,
    activeSubtitleIndex: null, // null = off
    isBitmapSubtitle: false, // true when active subtitle is burned into video
    subtitleSize: 'medium',
    subtitleStyle: 'classic',
  })

  const openPlayer = useCallback(async ({ type, episodeId, seriesId, movieId, title, subtitle, filePath, startTime }) => {
    setLaunching(true)
    try {
      // Tell main process what we're playing
      if (type === 'episode') {
        await api.setPlaybackEpisode(episodeId.id, episodeId.whId)
      } else if (type === 'movie') {
        await api.setPlaybackMovie(movieId)
      }

      // Load saved preferences for this series/movie (non-blocking — failure is OK)
      let prefs = null
      try {
        const prefPromise = api.getPlaybackPreferences({
          type,
          seriesId: type === 'episode' ? (seriesId || null) : null,
          movieId: type === 'movie' ? movieId : null,
        })
        // Timeout after 1s — don't let prefs lookup block playback
        const timeout = new Promise(resolve => setTimeout(() => resolve(null), 1000))
        prefs = await Promise.race([prefPromise, timeout])
      } catch {}

      // Start the transcoder — pass preferences so the backend picks the right
      // audio/subtitle track from the start (no post-start switching needed)
      const result = await api.startPlayback(filePath, startTime || 0, prefs)
      if (result.error) {
        console.error('Failed to start playback:', result.error)
        showToast(result.error, { type: 'error', duration: 6000 })
        setLaunching(false)
        return
      }

      setPlayerState({
        open: true,
        streamUrl: result.streamUrl,
        subtitleUrl: result.subtitleUrl,
        duration: result.duration,
        startTime: startTime || 0,
        seekBase: result.seekBase ?? startTime ?? 0,
        title: title || '',
        subtitle: subtitle || '',
        type,
        episodeId: type === 'episode' ? episodeId?.id : null,
        seriesId: type === 'episode' ? (seriesId || null) : null,
        movieId: type === 'movie' ? movieId : null,
        sessionId: Date.now(),
        audioStreams: result.audioStreams || [],
        subtitleStreams: result.subtitleStreams || [],
        activeAudioIndex: result.activeAudioIndex ?? null,
        activeSubtitleIndex: result.activeSubtitleIndex ?? null,
        isBitmapSubtitle: result.isBitmapSubtitle || false,
        subtitleSize: prefs?.subtitleSize || 'medium',
        subtitleStyle: prefs?.subtitleStyle || 'classic',
      })
    } catch (err) {
      console.error('openPlayer error:', err)
      showToast('Playback failed: ' + (err.message || 'Unknown error'), { type: 'error' })
    } finally {
      setLaunching(false)
    }
  }, [showToast, api])

  const closePlayer = useCallback((finalTime, finalDuration) => {
    setPlayerState(prev => ({ ...prev, open: false, streamUrl: null }))
    window.dispatchEvent(new Event('playback-stopped'))
    api.stopPlayback(finalTime, finalDuration).catch(() => {})
  }, [api])

  // Auto-play next episode in the series
  const playNextEpisode = useCallback(async () => {
    // Read current state synchronously before any async work
    let currentEpisodeId = null
    let currentSeriesId = null
    setPlayerState(prev => {
      currentEpisodeId = prev.episodeId
      currentSeriesId = prev.seriesId
      return prev
    })

    if (!currentEpisodeId) {
      closePlayer()
      return
    }

    try {
      // Look up the next episode
      const nextData = await api.getNextEpisode(currentEpisodeId)
      if (!nextData || !nextData.episode) {
        // No next episode — close the player
        closePlayer()
        return
      }

      const nextEp = nextData.episode

      // Stop current playback (ffmpeg cleanup) — fire and forget
      await api.stopPlayback().catch(() => {})

      // Play the next episode (same flow as SeriesShow.handlePlay)
      const result = await api.playEpisode(nextEp.id)
      if (!result || result.error) {
        closePlayer()
        return
      }

      // Open the player with the new episode
      await openPlayer({
        type: 'episode',
        episodeId: { id: result.episode_id, whId: result.watch_history_id },
        seriesId: result.series_id,
        filePath: result.file_path,
        startTime: result.start_time,
        title: nextData.seriesName || '',
        subtitle: nextEp.code + ' — ' + (nextEp.title || ''),
      })
    } catch (err) {
      console.error('playNextEpisode error:', err)
      showToast('Failed to play next episode: ' + (err.message || 'Unknown error'), { type: 'error' })
      closePlayer()
    }
  }, [closePlayer, openPlayer, showToast, api])

  // Helper to persist current audio/subtitle preference
  const savePreferences = useCallback((state, overrides = {}) => {
    const audioIndex = overrides.activeAudioIndex ?? state.activeAudioIndex
    const subtitleIndex = overrides.activeSubtitleIndex !== undefined ? overrides.activeSubtitleIndex : state.activeSubtitleIndex

    const audioStream = state.audioStreams.find(s => s.index === audioIndex)
    const subtitleStream = subtitleIndex != null ? state.subtitleStreams.find(s => s.index === subtitleIndex) : null

    api.savePlaybackPreferences({
      type: state.type,
      seriesId: state.seriesId,
      movieId: state.movieId,
      audioLanguage: audioStream?.language || null,
      subtitleLanguage: subtitleStream?.language || null,
      subtitleOff: subtitleIndex == null,
      subtitleSize: overrides.subtitleSize || state.subtitleSize || 'medium',
      subtitleStyle: overrides.subtitleStyle || state.subtitleStyle || 'classic',
    }).catch(() => {})
  }, [api])

  // Seek — restarts ffmpeg at new position, updates streamUrl in state
  // so the MSE useEffect picks it up automatically.
  const seekPlayback = useCallback(async (absoluteTime) => {
    try {
      const result = await api.seekPlayback(absoluteTime)
      if (result && result.streamUrl) {
        setPlayerState(prev => ({
          ...prev,
          streamUrl: result.streamUrl,
          seekBase: result.seekBase ?? absoluteTime,
          sessionId: Date.now(),
        }))
        return result
      }
    } catch (err) {
      console.error('seekPlayback error:', err)
    }
    return null
  }, [api])

  // Switch audio track — restarts ffmpeg at current position with new audio
  const switchAudio = useCallback(async (audioStreamIndex, currentVideoTime) => {
    try {
      const result = await api.switchAudio(audioStreamIndex, currentVideoTime)
      if (result && result.streamUrl) {
        setPlayerState(prev => {
          const next = {
            ...prev,
            streamUrl: result.streamUrl,
            seekBase: result.seekBase ?? (prev.seekBase + currentVideoTime),
            activeAudioIndex: audioStreamIndex,
            sessionId: Date.now(),
          }
          savePreferences(next)
          return next
        })
        return result
      }
    } catch (err) {
      console.error('switchAudio error:', err)
    }
    return null
  }, [savePreferences, api])

  // Switch subtitle track — re-extracts subtitle or disables
  const switchSubtitle = useCallback(async (subtitleStreamIndex) => {
    try {
      const result = await api.switchSubtitle(subtitleStreamIndex)
      if (result) {
        if (result.error) {
          console.warn('[Subtitle] switchSubtitle error:', result.error)
        }
        setPlayerState(prev => {
          const next = { ...prev, activeSubtitleIndex: subtitleStreamIndex, subtitleUrl: result.subtitleUrl, isBitmapSubtitle: false }
          savePreferences(next, { activeSubtitleIndex: subtitleStreamIndex })
          return next
        })
        return result
      }
    } catch (err) {
      console.error('switchSubtitle error:', err)
    }
    return null
  }, [savePreferences])

  // Switch bitmap subtitle track — restarts ffmpeg with overlay burn-in (or disables)
  const switchBitmapSubtitle = useCallback(async (subtitleStreamIndex, currentVideoTime) => {
    try {
      const result = await api.switchBitmapSubtitle(subtitleStreamIndex, currentVideoTime)
      if (result && result.streamUrl) {
        setPlayerState(prev => {
          const isBitmap = subtitleStreamIndex != null
          const next = {
            ...prev,
            streamUrl: result.streamUrl,
            seekBase: result.seekBase ?? (prev.seekBase + currentVideoTime),
            activeSubtitleIndex: subtitleStreamIndex,
            isBitmapSubtitle: isBitmap,
            subtitleUrl: null, // bitmap subs are burned in — no VTT track
            sessionId: Date.now(),
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

  // Update subtitle size/style and persist
  const setSubtitleAppearance = useCallback(({ subtitleSize, subtitleStyle }) => {
    setPlayerState(prev => {
      const next = { ...prev }
      if (subtitleSize !== undefined) next.subtitleSize = subtitleSize
      if (subtitleStyle !== undefined) next.subtitleStyle = subtitleStyle
      savePreferences(next, { subtitleSize: next.subtitleSize, subtitleStyle: next.subtitleStyle })
      return next
    })
  }, [savePreferences])

  // Listen for async subtitle extraction results pushed from main process.
  // Subtitles are extracted in the background after playback starts so the
  // video begins immediately without waiting for subtitle extraction to finish.
  useEffect(() => {
    if (!api.onSubtitlesReady) return
    const cleanup = api.onSubtitlesReady(({ subtitleUrl, subtitleStreamIndex }) => {
      setPlayerState(prev => {
        // Only apply if player is open and still expects this subtitle track
        if (!prev.open || prev.activeSubtitleIndex !== subtitleStreamIndex) return prev
        return { ...prev, subtitleUrl }
      })
    })
    return cleanup
  }, [api])

  const contextValue = useMemo(() => ({
    playerState, launching, openPlayer, closePlayer, playNextEpisode, seekPlayback, switchAudio, switchSubtitle, switchBitmapSubtitle, setSubtitleAppearance
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
