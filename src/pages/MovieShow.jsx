import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import { usePlayer } from '../context/PlayerContext'
import { genresList, formatTime, progressPercent, runtimeDisplay, isInProgress } from '../utils'

const PlaySvg = ({ size = 20 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>
)

const MoreSvg = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor">
    <circle cx="12" cy="5" r="2" />
    <circle cx="12" cy="12" r="2" />
    <circle cx="12" cy="19" r="2" />
  </svg>
)

export default function MovieShow() {
  const { slug } = useParams()
  const navigate = useNavigate()
  const { openPlayer } = usePlayer()
  const [movie, setMovie] = useState(null)
  const [loading, setLoading] = useState(true)
  const [vlcAvailable, setVlcAvailable] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRef = useRef(null)
  const menuBtnRef = useRef(null)

  const loadData = useCallback(async () => {
    try {
      const [m, hasVlc] = await Promise.all([
        window.api.getMovie(slug),
        window.api.checkVlc(),
      ])
      if (!m) { navigate('/movies'); return }
      setMovie(m)
      setVlcAvailable(hasVlc)
    } catch (err) {
      console.error('Failed to load movie:', err)
    } finally {
      setLoading(false)
    }
  }, [slug, navigate])

  useEffect(() => {
    loadData()
    const handleStop = () => loadData()
    window.addEventListener('playback-stopped', handleStop)
    const unsubVlc = window.api.onVlcPlaybackEnded(() => loadData())
    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
    }
  }, [loadData])

  const handlePlay = async () => {
    const result = await window.api.playMovie(slug)
    if (result && !result.error) {
      await openPlayer({
        type: 'movie',
        movieId: result.movie_id,
        filePath: result.file_path,
        startTime: result.start_time,
        title: movie?.title || '',
      })
      loadData()
    }
  }

  const handleToggle = async () => {
    await window.api.toggleMovie(slug)
    loadData()
  }

  const handleOpenInVlc = async () => {
    if (!movie?.file_path) return
    const result = await window.api.openInVlc({ filePath: movie.file_path, movieId: movie.id })
    if (result?.error) console.error('Open in VLC failed:', result.error)
  }

  const handleOpenInDefault = async () => {
    if (!movie?.file_path) return
    const result = await window.api.openInDefault(movie.file_path)
    if (result?.error) console.error('Open in Default Player failed:', result.error)
  }

  // Click-outside to close menu
  useEffect(() => {
    if (!menuOpen) return
    const handleClick = (e) => {
      if (menuRef.current && !menuRef.current.contains(e.target) &&
          menuBtnRef.current && !menuBtnRef.current.contains(e.target)) {
        setMenuOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [menuOpen])

  const handleRefresh = async () => {
    await window.api.refreshMovieMetadata(slug)
    loadData()
  }

  const handleRemove = async () => {
    if (!confirm(`Remove '${movie.title}' from library?`)) return
    await window.api.destroyMovie(slug)
    navigate('/movies')
  }

  if (loading) return (
    <>
      <Navbar active="Movies" />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  if (!movie) return null

  const genres = genresList(movie.genres)
  const inProgress = isInProgress(movie)
  const pct = progressPercent(movie.progress_seconds, movie.duration_seconds)
  const runtime = runtimeDisplay(movie.runtime)
  const filename = movie.file_path ? movie.file_path.split('/').pop() : null

  return (
    <>
      <Navbar
        active="Movies"
        actions={
          <>
            <button className="topnav-btn" onClick={handleRefresh}>Refresh</button>
            <button className="topnav-btn topnav-btn--danger" onClick={handleRemove}>Remove</button>
          </>
        }
      />
      <NowPlaying />

      {/* Hero */}
      <header
        className="show-hero"
        style={movie.poster_url ? { '--poster': `url(${movie.poster_url})` } : undefined}
      >
        <div className="show-hero-bg" />
        <div className="show-hero-content">
          {movie.poster_url && (
            <div className="show-poster">
              <img src={movie.poster_url} alt={movie.title} />
            </div>
          )}
          <div className="show-info">
            <h1 className="show-title">{movie.title}</h1>
            <div className="show-meta-row">
              {movie.year && <span>{movie.year}</span>}
              {runtime && <span>{runtime}</span>}
              {movie.rating && <span className="show-rating">{'\u2605'} {movie.rating}</span>}
              {movie.director && <span className="movie-director">Dir. {movie.director}</span>}
              {movie.imdb_id && (
                <a
                  href={`https://www.imdb.com/title/${movie.imdb_id}/`}
                  target="_blank"
                  rel="noreferrer"
                  className="show-imdb"
                >
                  IMDb
                </a>
              )}
            </div>
            {genres.length > 0 && (
              <div className="show-genres">{genres.join('  \u00B7  ')}</div>
            )}
            {movie.description && (
              <p className="show-description">{movie.description}</p>
            )}
          </div>
        </div>
      </header>

      <main className="show-main">
        {/* Play / Resume CTA */}
        {inProgress ? (
          <div className="cta-card cta-resume">
            <div className="cta-content">
              <span className="cta-label">Resume Where You Left Off</span>
              <div className="cta-progress-row">
                <div className="cta-progress-track">
                  <div className="cta-progress-fill" style={{ width: `${pct}%` }} />
                </div>
                <span className="cta-progress-text">
                  {formatTime(movie.progress_seconds)} / {formatTime(movie.duration_seconds)} ({pct}%)
                </span>
              </div>
            </div>
            <button className="btn-play-cta btn-play-cta--resume" onClick={handlePlay}>
              <PlaySvg /> Resume
            </button>
          </div>
        ) : (
          <div className="cta-card">
            <div className="cta-content">
              <span className="cta-label">{movie.watched ? 'Watch Again' : 'Start Watching'}</span>
              <div className="cta-episode">
                <span className="cta-ep-title">{movie.title}</span>
              </div>
            </div>
            <button className="btn-play-cta" onClick={handlePlay}>
              <PlaySvg /> Play
            </button>
          </div>
        )}

        {/* Movie Info Cards */}
        <div className="movie-detail-section">
          <div className="stats-row">
            {movie.runtime && (
              <div className="stat"><span className="stat-val">{runtime}</span><span className="stat-lbl">Runtime</span></div>
            )}
            {movie.rating && (
              <div className="stat"><span className="stat-val">{movie.rating}</span><span className="stat-lbl">IMDb Rating</span></div>
            )}
            <div className="stat">
              <span className="stat-val" dangerouslySetInnerHTML={{ __html: movie.watched ? '&#10003;' : '&mdash;' }} />
              <span className="stat-lbl">Watched</span>
            </div>
          </div>

          <div className="movie-actions-row">
            <div className="ep-more-wrap">
              <button
                ref={menuBtnRef}
                className={`btn-ep-more${menuOpen ? ' active' : ''}`}
                onClick={() => setMenuOpen(!menuOpen)}
              >
                <MoreSvg />
              </button>
              {menuOpen && (
                <div ref={menuRef} className="ep-popover">
                  <button
                    className="ep-popover-item"
                    onClick={() => { handleToggle(); setMenuOpen(false) }}
                  >
                    <span className="ep-popover-icon">{movie.watched ? '\u21A9' : '\u2713'}</span>
                    <span>{movie.watched ? 'Mark Unwatched' : 'Mark Watched'}</span>
                  </button>
                  {vlcAvailable && (
                    <button
                      className="ep-popover-item"
                      onClick={() => { handleOpenInVlc(); setMenuOpen(false) }}
                    >
                      <span className="ep-popover-icon">{'\u25B6'}</span>
                      <span>Open in VLC</span>
                    </button>
                  )}
                  <button
                    className="ep-popover-item"
                    onClick={() => { handleOpenInDefault(); setMenuOpen(false) }}
                  >
                    <span className="ep-popover-icon">{'\u2197'}</span>
                    <span>Open in Default Player</span>
                  </button>
                </div>
              )}
            </div>
          </div>

          {filename && (
            <div className="movie-file-info">
              <span className="movie-file-label">File</span>
              <span className="movie-file-path">{filename}</span>
            </div>
          )}
        </div>
      </main>
    </>
  )
}
