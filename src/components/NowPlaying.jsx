import { usePlayback } from '../hooks/usePlayback'
import { formatTime } from '../utils'

export default function NowPlaying() {
  const playback = usePlayback()

  if (!playback || !playback.playing) return null

  const title = playback.type === 'movie'
    ? playback.movie_title
    : `${playback.series_name || ''} \u2014 ${playback.episode_code || ''} ${playback.episode_title || ''}`

  const pct = playback.position ? (playback.position * 100) : 0

  return (
    <div className="now-playing-bar">
      <div className="np-dot" />
      <span className="np-label">Now Playing</span>
      <span className="np-title">{title}</span>
      <span className="np-time">
        {formatTime(playback.time)} / {formatTime(playback.length)}
      </span>
      <div className="np-progress">
        <div className="np-progress-fill" style={{ width: `${pct}%` }} />
      </div>
    </div>
  )
}
