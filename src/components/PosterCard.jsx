import { useNavigate } from 'react-router-dom'
import { refractive, lip } from '@hashintel/refractive'
import { genresList, premiereYear, statusClass, progressPercent, runtimeDisplay, isInProgress } from '../utils'

export default function PosterCard({ item, type = 'series', resumable = false }) {
  const navigate = useNavigate()

  const name = type === 'series' ? item.name : item.title
  const poster = item.poster_url
  const rating = item.rating
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

  return (
    <div className="series-card" onClick={() => navigate(href)}>
      <div className="card-poster">
        {poster ? (
          <img src={poster} alt={name} loading="lazy" />
        ) : (
          <div className="card-poster-fallback">{name?.[0] || '?'}</div>
        )}
        <div className="card-overlay">
          {rating ? <refractive.span className="card-rating" refraction={{ radius: 8, blur: 4, bezelWidth: 1, glassThickness: 50, specularOpacity: 0.3, refractiveIndex: 1.6, bezelHeightFn: lip }}>{rating}</refractive.span> : <span />}
          {type === 'series' && resumable && <span className="card-badge-resume">Resume</span>}
          {type === 'movie' && movieInProgress && <span className="card-badge-resume">Resume</span>}
          {type === 'movie' && item.watched && !movieInProgress && <span className="card-badge-watched">Watched</span>}
        </div>
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
