import { createContext, useContext, useState, useCallback } from 'react'
import { useToast } from './ToastContext'

const PlayerContext = createContext(null)

export function PlayerProvider({ children }) {
  const { showToast } = useToast()
  const [launching, setLaunching] = useState(false)
  const [playerState, setPlayerState] = useState({
    open: false,
    streamUrl: null,
    subtitleUrl: null,
    duration: 0,
    startTime: 0,
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
    subtitleSize: 'medium',
    subtitleStyle: 'classic',
  })

  const openPlayer = useCallback(async ({ type, episodeId, seriesId, movieId, title, subtitle, filePath, startTime }) => {
    setLaunching(true)
    try {
      // Tell main process what we're playing
      if (type === 'episode') {
        await window.api.setPlaybackEpisode(episodeId.id, episodeId.whId)
      } else if (type === 'movie') {
        await window.api.setPlaybackMovie(movieId)
      }

      // Load saved preferences for this series/movie (non-blocking — failure is OK)
      let prefs = null
      try {
        const prefPromise = window.api.getPlaybackPreferences({
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
      const result = await window.api.startPlayback(filePath, startTime || 0, prefs)
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
        subtitleSize: prefs?.subtitleSize || 'medium',
        subtitleStyle: prefs?.subtitleStyle || 'classic',
      })
    } catch (err) {
      console.error('openPlayer error:', err)
      showToast('Playback failed: ' + (err.message || 'Unknown error'), { type: 'error' })
    } finally {
      setLaunching(false)
    }
  }, [showToast])

  const closePlayer = useCallback((finalTime, finalDuration) => {
    setPlayerState(prev => ({ ...prev, open: false, streamUrl: null }))
    window.dispatchEvent(new Event('playback-stopped'))
    window.api.stopPlayback(finalTime, finalDuration).catch(() => {})
  }, [])

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
      const nextData = await window.api.getNextEpisode(currentEpisodeId)
      if (!nextData || !nextData.episode) {
        // No next episode — close the player
        closePlayer()
        return
      }

      const nextEp = nextData.episode

      // Stop current playback (ffmpeg cleanup) — fire and forget
      await window.api.stopPlayback().catch(() => {})

      // Play the next episode (same flow as SeriesShow.handlePlay)
      const result = await window.api.playEpisode(nextEp.id)
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
  }, [closePlayer, openPlayer, showToast])

  // Helper to persist current audio/subtitle preference
  const savePreferences = useCallback((state, overrides = {}) => {
    const audioIndex = overrides.activeAudioIndex ?? state.activeAudioIndex
    const subtitleIndex = overrides.activeSubtitleIndex !== undefined ? overrides.activeSubtitleIndex : state.activeSubtitleIndex

    const audioStream = state.audioStreams.find(s => s.index === audioIndex)
    const subtitleStream = subtitleIndex != null ? state.subtitleStreams.find(s => s.index === subtitleIndex) : null

    window.api.savePlaybackPreferences({
      type: state.type,
      seriesId: state.seriesId,
      movieId: state.movieId,
      audioLanguage: audioStream?.language || null,
      subtitleLanguage: subtitleStream?.language || null,
      subtitleOff: subtitleIndex == null,
      subtitleSize: overrides.subtitleSize || state.subtitleSize || 'medium',
      subtitleStyle: overrides.subtitleStyle || state.subtitleStyle || 'classic',
    }).catch(() => {})
  }, [])

  // Switch audio track — restarts ffmpeg at current position with new audio
  const switchAudio = useCallback(async (audioStreamIndex, currentVideoTime) => {
    try {
      const result = await window.api.switchAudio(audioStreamIndex, currentVideoTime)
      if (result && result.streamUrl) {
        setPlayerState(prev => {
          const next = { ...prev, activeAudioIndex: audioStreamIndex, sessionId: Date.now() }
          savePreferences(next)
          return next
        })
        return result
      }
    } catch (err) {
      console.error('switchAudio error:', err)
    }
    return null
  }, [savePreferences])

  // Switch subtitle track — re-extracts subtitle or disables
  const switchSubtitle = useCallback(async (subtitleStreamIndex) => {
    try {
      const result = await window.api.switchSubtitle(subtitleStreamIndex)
      if (result) {
        setPlayerState(prev => {
          const next = { ...prev, activeSubtitleIndex: subtitleStreamIndex, subtitleUrl: result.subtitleUrl }
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

  return (
    <PlayerContext.Provider value={{ playerState, launching, openPlayer, closePlayer, playNextEpisode, switchAudio, switchSubtitle, setSubtitleAppearance }}>
      {children}
    </PlayerContext.Provider>
  )
}

export function usePlayer() {
  const ctx = useContext(PlayerContext)
  if (!ctx) throw new Error('usePlayer must be used within PlayerProvider')
  return ctx
}
