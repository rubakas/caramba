import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { genresList, premiereYear, statusClass, progressPercent, runtimeDisplay, isInProgress } from '../utils'

// Detect Android TV
const isTV = typeof window !== 'undefined' && window.Capacitor?.isNativePlatform?.() === true

// Resize IMDB/Amazon image URLs for TV (less memory, faster decode)
// Original: ...@@._V1_.jpg (~420KB)
// Resized:  ...@@._V1_SX300.jpg (~36KB)
const getTVPosterUrl = (url) => {
  if (!url || !isTV) return url
  // IMDB/Amazon images - resize to 300px width
  if (url.includes('m.media-amazon.com') && url.includes('._V1_')) {
    return url.replace('._V1_.jpg', '._V1_SX300.jpg')
  }
  return url
}

export default function PosterCard({ item, type = 'series', resumable = false, autoFocus = false }) {
  const navigate = useNavigate()
  const cardRef = useRef(null)

  const name = type === 'series' ? item.name : item.title
  const poster = getTVPosterUrl(item.poster_url) // Use medium-sized images on TV
  const slug = item.slug
  const href = type === 'series' ? `/series/${slug}` : `/movies/${slug}`

  const genres = genresList(item.genres).slice(0, 3)
  const year = type === 'series' ? premiereYear(item.premiered) : item.year
  const status = type === 'series' ? item.status : null

  // Progress for series
  const totalEps = item.total_episodes || 0
  const watchedEps = item.watched_episodes || 0
  const seriesProgress = totalEps > 0 ? Math.round((watchedEps / totalEps) * 100) : 0

  // Progress for movies
  const movieInProgress = type === 'movie' && isInProgress(item)
  const movieProgress = type === 'movie' ? progressPercent(item.progress_seconds, item.duration_seconds) : 0

  const handleKeyDown = (e) => {
    // Handle Enter/Space for D-pad select
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault()
      navigate(href)
    }
  }

  // Auto-focus first card on Android TV
  useEffect(() => {
    if (autoFocus && cardRef.current) {
      cardRef.current.focus({ preventScroll: true })
    }
  }, [autoFocus])

  return (
    <div 
      ref={cardRef}
      className="series-card" 
      onClick={() => navigate(href)}
      onKeyDown={handleKeyDown}
      tabIndex={0}
      role="button"
      aria-label={name}
    >
      <div className="card-poster">
        {poster ? (
          <img 
            src={poster} 
            alt={name} 
            loading="lazy"
            decoding="async"
          />
        ) : (
          <div className="card-poster-fallback">{name?.[0] || '?'}</div>
        )}
        {type === 'series' && watchedEps > 0 && (
          <div className="card-progress-track">
            <div className="card-progress-fill" style={{ width: `${seriesProgress}%` }} />
          </div>
        )}
        {type === 'movie' && movieInProgress && (
          <div className="card-progress-track">
            <div className="card-progress-fill" style={{ width: `${movieProgress}%` }} />
          </div>
        )}
      </div>
      <div className="card-body">
        <h3 className="card-title">{name}</h3>
        <p className="card-meta">
          {year && <span>{year}</span>}
          {status && (
            <span className={`card-status card-status--${statusClass(status)}`}>{status}</span>
          )}
          {type === 'movie' && item.runtime && (
            <span>{runtimeDisplay(item.runtime)}</span>
          )}
        </p>
        {genres.length > 0 && (
          <div className="card-genres">{genres.join('  \u00B7  ')}</div>
        )}
        {type === 'series' && watchedEps > 0 && (
          <p className="card-progress-label">{watchedEps}/{totalEps} episodes</p>
        )}
      </div>
    </div>
  )
}
