import { useState, useRef, useEffect } from 'react'
import { refractive } from '@hashintel/refractive'
import { formatTime, progressPercent, truncate } from '../utils'

const PlaySvg = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

const MoreSvg = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
    <circle cx="12" cy="5" r="2" />
    <circle cx="12" cy="12" r="2" />
    <circle cx="12" cy="19" r="2" />
  </svg>
)

export default function EpisodeRow({ episode, isCurrent, onPlay, onToggle, onOpenInVlc, onOpenInDefault, vlcAvailable }) {
  const [expanded, setExpanded] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRef = useRef(null)
  const btnRef = useRef(null)

  const ep = episode
  const watched = !!ep.watched
  const inProgress = ep.progress_seconds > 0 && ep.duration_seconds > 0 && (ep.progress_seconds / ep.duration_seconds) < 0.9
  const pct = progressPercent(ep.progress_seconds, ep.duration_seconds)
  const desc = ep.description || ''
  const isLong = desc.length > 120

  // Click-outside to close menu
  useEffect(() => {
    if (!menuOpen) return
    const handleClick = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target) &&
          btnRef.current && !btnRef.current.contains(e.target)) {
        setMenuOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [menuOpen])

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
        <div className="ep-more-wrap">
          <button
            ref={btnRef}
            className={`btn-ep-more${menuOpen ? ' active' : ''}`}
            onClick={() => setMenuOpen(!menuOpen)}
          >
            <MoreSvg />
          </button>
          {menuOpen && (
            <refractive.div ref={menuRef} className="ep-popover" refraction={{ radius: 10, blur: 8, bezelWidth: 2, glassThickness: 80, specularOpacity: 0.15, refractiveIndex: 1.45 }}>
              <button
                className="ep-popover-item"
                onClick={() => { onToggle(ep.id); setMenuOpen(false) }}
              >
                <span className="ep-popover-icon">{watched ? '\u21A9' : '\u2713'}</span>
                <span>{watched ? 'Mark Unwatched' : 'Mark Watched'}</span>
              </button>
              {vlcAvailable && (
                <button
                  className="ep-popover-item"
                  onClick={() => { onOpenInVlc(ep.id); setMenuOpen(false) }}
                >
                  <span className="ep-popover-icon">{'\u25B6'}</span>
                  <span>Open in VLC</span>
                </button>
              )}
              <button
                className="ep-popover-item"
                onClick={() => { onOpenInDefault(ep.id); setMenuOpen(false) }}
              >
                <span className="ep-popover-icon">{'\u2197'}</span>
                <span>Open in Default Player</span>
              </button>
            </refractive.div>
          )}
        </div>
      </div>
    </div>
  )
}
