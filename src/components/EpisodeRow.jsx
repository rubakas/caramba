import { useState, useRef, useEffect } from 'react'
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

const DownloadSvg = ({ size = 14 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
    <polyline points="7 10 12 15 17 10" />
    <line x1="12" y1="15" x2="12" y2="3" />
  </svg>
)

const DownloadedSvg = ({ size = 14 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 17V3" />
    <path d="M7 12l5 5 5-5" />
    <path d="M3 21h18" />
  </svg>
)

export default function EpisodeRow({ episode, isCurrent, onPlay, onToggle, onOpenInVlc, onOpenInDefault, onDownload, onDeleteDownload, vlcAvailable, downloadProgress }) {
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

  // Download state
  const dl = ep.download
  const isDownloaded = dl && dl.status === 'complete'
  // Consider downloading if either the DB record says so OR we have live progress from IPC
  const isDownloading = (dl && dl.status === 'downloading') || downloadProgress != null
  // Use live progress from IPC event if available, otherwise DB value
  const dlProgress = isDownloading ? (downloadProgress != null ? downloadProgress : (dl ? dl.progress : 0)) : 0

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
          <span className="ep-name">
            {ep.title || ep.code}
            {isDownloaded && (
              <span className="ep-dl-badge ep-dl-badge--complete" title="Downloaded">
                <DownloadedSvg size={13} />
              </span>
            )}
          </span>
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
        {isDownloading && (
          <div className="ep-dl-progress">
            <div className="ep-dl-progress-track">
              <div className="ep-dl-progress-fill" style={{ width: `${Math.round(dlProgress * 100)}%` }} />
            </div>
            <span className="ep-dl-progress-label">Downloading {Math.round(dlProgress * 100)}%</span>
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
            <div ref={menuRef} className="ep-popover">
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
              <div className="ep-popover-divider" />
              {isDownloaded ? (
                <button
                  className="ep-popover-item ep-popover-item--danger"
                  onClick={() => { onDeleteDownload(ep.id); setMenuOpen(false) }}
                >
                  <span className="ep-popover-icon">{'\u2715'}</span>
                  <span>Delete Download</span>
                </button>
              ) : !isDownloading ? (
                <button
                  className="ep-popover-item"
                  onClick={() => { onDownload(ep.id); setMenuOpen(false) }}
                >
                  <span className="ep-popover-icon">{'\u2913'}</span>
                  <span>Download</span>
                </button>
              ) : null}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
