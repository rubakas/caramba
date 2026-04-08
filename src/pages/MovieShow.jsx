import { useState, useEffect, useCallback, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { refractive } from '@hashintel/refractive'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import { usePlayer } from '../context/PlayerContext'
import { useToast } from '../context/ToastContext'
import { useGlassConfig } from '../config/useGlassConfig'
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
  const { openPlayer, launching } = usePlayer()
  const { showToast } = useToast()
  const [movie, setMovie] = useState(null)
  const [loading, setLoading] = useState(true)
  const [vlcAvailable, setVlcAvailable] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const [dlProgress, setDlProgress] = useState(null) // live download progress 0-1
  const menuRef = useRef(null)
  const menuBtnRef = useRef(null)
  const ctaCardGlass = useGlassConfig('cta-card')
  const playCtaGlass = useGlassConfig('play-cta')
  const navBtnGlass = useGlassConfig('nav-btn')
  const epMoreGlass = useGlassConfig('ep-more')
  const popoverGlass = useGlassConfig('popover')
  const statChipGlass = useGlassConfig('stat-chip')

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

    // Listen for download progress events
    const unsubDl = window.api.onMediaDownloadProgress((data) => {
      if (data.movieId) {
        if (data.status === 'downloading') {
          setDlProgress(data.progress)
        } else {
          setDlProgress(null)
          loadData()
        }
      }
    })

    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
      unsubDl()
    }
  }, [loadData])

  const handlePlay = async () => {
    const result = await window.api.playMovie(slug)
    if (!result || result.error) {
      showToast(result?.error || 'Failed to start playback', { type: 'error' })
      return
    }
    await openPlayer({
      type: 'movie',
      movieId: result.movie_id,
      filePath: result.file_path,
      startTime: result.start_time,
      title: movie?.title || '',
    })
    loadData()
  }

  const handleToggle = async () => {
    await window.api.toggleMovie(slug)
    loadData()
  }

  const handleOpenInVlc = async () => {
    if (!movie?.file_path) return
    const result = await window.api.openInVlc({ filePath: movie.file_path, movieId: movie.id })
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleOpenInDefault = async () => {
    if (!movie?.file_path) return
    const result = await window.api.openInDefault(movie.file_path, null, movie.id)
    if (result?.error) showToast(result.error, { type: 'error' })
  }

  const handleDownload = async () => {
    if (!movie) return
    showToast('Starting download...', { type: 'info', duration: 2000 })
    const result = await window.api.downloadMovie(movie.id)
    if (result?.error) {
      showToast(result.error, { type: 'error' })
    } else if (result?.ok) {
      showToast('Download complete', { type: 'success' })
      loadData()
    }
  }

  const handleDeleteDownload = async () => {
    if (!movie) return
    await window.api.deleteDownloadMovie(movie.id)
    showToast('Download deleted', { type: 'info', duration: 2000 })
    loadData()
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

  const handleRelocate = async () => {
    const files = await window.api.selectFiles()
    if (!files || files.length === 0) return
    const result = await window.api.relocateMovie(slug, files[0])
    if (result?.error) {
      showToast(result.error, { type: 'error' })
    } else {
      showToast('Movie relocated successfully', { type: 'success' })
      loadData()
    }
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

  // Download state
  const dl = movie.download
  const isDownloaded = dl && dl.status === 'complete'
  // Consider downloading if either the DB record says so OR we have live progress from IPC
  const isDownloading = (dl && dl.status === 'downloading') || dlProgress != null
  const liveDlPct = isDownloading ? (dlProgress != null ? dlProgress : (dl ? dl.progress : 0)) : 0

  const renderMenu = () => (
    <>
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
      <div className="ep-popover-divider" />
      {isDownloaded ? (
        <button
          className="ep-popover-item ep-popover-item--danger"
          onClick={() => { handleDeleteDownload(); setMenuOpen(false) }}
        >
          <span className="ep-popover-icon">{'\u2715'}</span>
          <span>Delete Download</span>
        </button>
      ) : !isDownloading ? (
        <button
          className="ep-popover-item"
          onClick={() => { handleDownload(); setMenuOpen(false) }}
        >
          <span className="ep-popover-icon">{'\u2913'}</span>
          <span>Download</span>
        </button>
      ) : null}
    </>
  )

  return (
    <>
      <Navbar
        active="Movies"
        actions={
          <>
            <refractive.button className="topnav-btn" onClick={handleRefresh} refraction={navBtnGlass}>Refresh</refractive.button>
            <refractive.button className="topnav-btn" onClick={handleRelocate} refraction={navBtnGlass}>Relocate</refractive.button>
            <refractive.button className="topnav-btn topnav-btn--danger" onClick={handleRemove} refraction={navBtnGlass}>Remove</refractive.button>
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
          <refractive.div className="cta-card cta-resume" refraction={ctaCardGlass}>
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
            <refractive.button className="btn-play-cta btn-play-cta--resume" disabled={launching} onClick={handlePlay} refraction={playCtaGlass}>
              {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Resume</>}
            </refractive.button>
          </refractive.div>
        ) : (
          <refractive.div className="cta-card" refraction={ctaCardGlass}>
            <div className="cta-content">
              <span className="cta-label">{movie.watched ? 'Watch Again' : 'Start Watching'}</span>
              <div className="cta-episode">
                <span className="cta-ep-title">{movie.title}</span>
              </div>
            </div>
            <refractive.button className="btn-play-cta" disabled={launching} onClick={handlePlay} refraction={playCtaGlass}>
              {launching ? <><span className="btn-spinner" /> Loading...</> : <><PlaySvg /> Play</>}
            </refractive.button>
          </refractive.div>
        )}

        {/* Movie Info Cards */}
        <div className="movie-detail-section">
          <div className="stats-row">
            {movie.runtime && (
              <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{runtime}</span><span className="stat-lbl">Runtime</span></refractive.div>
            )}
            {movie.rating && (
              <refractive.div className="stat" refraction={statChipGlass}><span className="stat-val">{movie.rating}</span><span className="stat-lbl">IMDb Rating</span></refractive.div>
            )}
            <refractive.div className="stat" refraction={statChipGlass}>
              <span className="stat-val" dangerouslySetInnerHTML={{ __html: movie.watched ? '&#10003;' : '&mdash;' }} />
              <span className="stat-lbl">Watched</span>
            </refractive.div>
            {isDownloaded && (
              <refractive.div className="stat stat--downloaded" refraction={statChipGlass}>
                <span className="stat-val">{'\u2913'}</span>
                <span className="stat-lbl">Downloaded</span>
              </refractive.div>
            )}
          </div>
          {isDownloading && (
            <div className="movie-dl-progress">
              <div className="movie-dl-progress-track">
                <div className="movie-dl-progress-fill" style={{ width: `${Math.round(liveDlPct * 100)}%` }} />
              </div>
              <span className="movie-dl-progress-label">Downloading {Math.round(liveDlPct * 100)}%</span>
            </div>
          )}

          {filename && (
            <div className="movie-file-info">
              <span className="movie-file-label">File</span>
              <span className="movie-file-path">{filename}</span>
              <div className="ep-more-wrap">
                <refractive.button
                  ref={menuBtnRef}
                  className={`btn-ep-more${menuOpen ? ' active' : ''}`}
                  onClick={() => setMenuOpen(!menuOpen)}
                  refraction={epMoreGlass}
                >
                  <MoreSvg />
                </refractive.button>
                {menuOpen && (
                  <refractive.div ref={menuRef} className="ep-popover" refraction={popoverGlass}>
                    {renderMenu()}
                  </refractive.div>
                )}
              </div>
            </div>
          )}
          {!filename && (
            <div className="movie-actions-row">
              <div className="ep-more-wrap">
                <refractive.button
                  ref={menuBtnRef}
                  className={`btn-ep-more${menuOpen ? ' active' : ''}`}
                  onClick={() => setMenuOpen(!menuOpen)}
                  refraction={epMoreGlass}
                >
                  <MoreSvg />
                </refractive.button>
                {menuOpen && (
                  <refractive.div ref={menuRef} className="ep-popover" refraction={popoverGlass}>
                    {renderMenu()}
                  </refractive.div>
                )}
              </div>
            </div>
          )}
        </div>
      </main>
    </>
  )
}
