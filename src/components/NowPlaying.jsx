import { useState, useEffect } from 'react'
import { usePlayer } from '../context/PlayerContext'
import { formatTime } from '../utils'

export default function NowPlaying() {
  const { playerState } = usePlayer()
  const [vlcStatus, setVlcStatus] = useState(null)

  // Poll playback:status for VLC external playback
  useEffect(() => {
    // Don't poll while in-app player is open
    if (playerState.open) {
      setVlcStatus(null)
      return
    }

    let active = true
    const poll = async () => {
      try {
        const status = await window.api.getPlaybackStatus()
        if (!active) return
        if (status?.playing && status.source === 'vlc') {
          setVlcStatus(status)
        } else {
          setVlcStatus(null)
        }
      } catch {
        if (active) setVlcStatus(null)
      }
    }

    poll()
    const timer = setInterval(poll, 3000)
    return () => { active = false; clearInterval(timer) }
  }, [playerState.open])

  // Listen for vlc-playback-ended to clear immediately
  useEffect(() => {
    const unsub = window.api.onVlcPlaybackEnded(() => setVlcStatus(null))
    return unsub
  }, [])

  // In-app player NowPlaying
  if (playerState.open) {
    const title = playerState.subtitle
      ? `${playerState.title} — ${playerState.subtitle}`
      : playerState.title

    return (
      <div className="now-playing-bar">
        <div className="np-dot" />
        <span className="np-label">Now Playing</span>
        <span className="np-title">{title}</span>
      </div>
    )
  }

  // VLC external playback NowPlaying
  if (vlcStatus) {
    let title = ''
    if (vlcStatus.type === 'episode') {
      title = vlcStatus.series_name
        ? `${vlcStatus.series_name} — ${vlcStatus.episode_code || ''} ${vlcStatus.episode_title || ''}`.trim()
        : vlcStatus.episode_title || 'Playing in VLC'
    } else if (vlcStatus.type === 'movie') {
      title = vlcStatus.movie_title || 'Playing in VLC'
    } else {
      title = 'Playing in VLC'
    }

    const time = vlcStatus.time || 0
    const duration = vlcStatus.duration || 0
    const pct = duration > 0 ? (time / duration) * 100 : 0

    return (
      <div className="now-playing-bar">
        <div className="np-dot" />
        <span className="np-label">VLC</span>
        <span className="np-title">{title}</span>
        {duration > 0 && (
          <>
            <span className="np-time">{formatTime(time)} / {formatTime(duration)}</span>
            <div className="np-progress">
              <div className="np-progress-fill" style={{ width: `${pct}%` }} />
            </div>
          </>
        )}
      </div>
    )
  }

  return null
}
