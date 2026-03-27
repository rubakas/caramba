import { useState } from 'react'
import { formatTime, progressPercent, truncate } from '../utils'

const PlaySvg = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

export default function EpisodeRow({ episode, isCurrent, onPlay, onToggle }) {
  const [expanded, setExpanded] = useState(false)

  const ep = episode
  const watched = !!ep.watched
  const inProgress = ep.progress_seconds > 0 && ep.duration_seconds > 0 && (ep.progress_seconds / ep.duration_seconds) < 0.9
  const pct = progressPercent(ep.progress_seconds, ep.duration_seconds)
  const desc = ep.description || ''
  const isLong = desc.length > 120

  const rowClass = [
    'ep-row',
    watched ? 'ep-row--watched' : '',
    isCurrent ? 'ep-row--current' : '',
  ].filter(Boolean).join(' ')

  return (
    <div className={rowClass}>
      <div className="ep-num">
        {watched ? (
          <span className="ep-watched-icon">{'\u2713'}</span>
        ) : (
          <span className="ep-episode-num">{ep.episode_number}</span>
        )}
      </div>
      <div className="ep-body">
        <div className="ep-top-row">
          <span className="ep-name">{ep.title || ep.code}</span>
          {ep.air_date && <span className="ep-date">{ep.air_date}</span>}
        </div>
        <span className="ep-code-label">{ep.code}</span>
        {desc && (
          <p
            className="ep-desc"
            style={{ cursor: isLong ? 'pointer' : 'default' }}
            onClick={() => isLong && setExpanded(!expanded)}
          >
            {expanded || !isLong ? desc : truncate(desc, 120)}
          </p>
        )}
        {inProgress && (
          <div className="ep-progress">
            <div className="ep-progress-track">
              <div className="ep-progress-fill" style={{ width: `${pct}%` }} />
            </div>
            <span className="ep-progress-label">
              {formatTime(ep.progress_seconds)} / {formatTime(ep.duration_seconds)}
            </span>
          </div>
        )}
      </div>
      <div className="ep-actions">
        <button className="btn-ep-play" onClick={() => onPlay(ep.id)}>
          <PlaySvg />
        </button>
        <button className="btn-ep-toggle" onClick={() => onToggle(ep.id)}>
          {watched ? 'Unwatch' : 'Watched'}
        </button>
      </div>
    </div>
  )
}
