import { useState, useEffect, useCallback, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { refractive } from '../config/refractive'
import Navbar from '../components/Navbar'
import { genresList, premiereYear, statusClass } from '../utils'
import { useGlassConfig } from '../config/useGlassConfig'
import { useApi } from '../context/ApiContext'

// -- SVG Icons ----------------------------------------------------

const BookmarkFilled = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><path d="M5 2h14a1 1 0 011 1v19.143a.5.5 0 01-.766.424L12 18.03l-7.234 4.536A.5.5 0 014 22.143V3a1 1 0 011-1z"/></svg>
)
const BookmarkOutline = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M5 2h14a1 1 0 011 1v19.143a.5.5 0 01-.766.424L12 18.03l-7.234 4.536A.5.5 0 014 22.143V3a1 1 0 011-1z"/></svg>
)
const CloseSvg = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
    <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
  </svg>
)

// -- Show Card (TV) -----------------------------------------------

function ShowCard({ show, onToggleWatchlist, onClick }) {
  const poster = show.poster_url
  const genres = genresList(show.genres).slice(0, 3)
  const year = premiereYear(show.premiered)

  return (
    <div className="discover-card" onClick={onClick}>
      <div className="discover-card-main">
        <div className="card-poster">
          {poster ? (
            <img src={poster} alt={show.name} loading="lazy" />
          ) : (
            <div className="card-poster-fallback">{show.name?.[0] || '?'}</div>
          )}
          <div className="card-overlay">
            {show.rating ? <span className="card-rating">{show.rating}</span> : <span />}
          </div>
        </div>
        <div className="card-body">
          <h3 className="card-title">{show.name}{show.in_library && <span className="card-badge-library">In Library</span>}</h3>
          <p className="card-meta">
            {year && <span>{year}</span>}
            {show.status && (
              <span className={`card-status card-status--${statusClass(show.status)}`}>{show.status}</span>
            )}
            {show.runtime && <span>{show.runtime}m</span>}
          </p>
          {genres.length > 0 && (
            <div className="card-genres">{genres.join('  \u00B7  ')}</div>
          )}
          {show.network && (
            <div className="discover-network">{show.network}</div>
          )}
        </div>
      </div>

      <button
        className={`discover-watchlist-btn${show.in_watchlist ? ' active' : ''}`}
        onClick={(e) => { e.stopPropagation(); onToggleWatchlist(show) }}
        title={show.in_watchlist ? 'Remove from Watchlist' : 'Add to Watchlist'}
      >
        {show.in_watchlist ? <BookmarkFilled /> : <BookmarkOutline />}
      </button>
    </div>
  )
}

// -- Movie Card ---------------------------------------------------

function MovieCard({ movie, onClick, onToggleWatchlist }) {
  return (
    <div className="discover-card" onClick={onClick}>
      <div className="discover-card-main">
        <div className="card-poster">
          {movie.poster_url ? (
            <img src={movie.poster_url} alt={movie.name} loading="lazy" />
          ) : (
            <div className="card-poster-fallback">{movie.name?.[0] || '?'}</div>
          )}
          <div className="card-overlay">
            {movie.rating ? <span className="card-rating">{movie.rating}</span> : <span />}
          </div>
        </div>
        <div className="card-body">
          <h3 className="card-title">{movie.name}{movie.in_library && <span className="card-badge-library">In Library</span>}</h3>
          <p className="card-meta">
            {movie.year && <span>{movie.year}</span>}
          </p>
        </div>
      </div>

      <button
        className={`discover-watchlist-btn${movie.in_watchlist ? ' active' : ''}`}
        onClick={(e) => { e.stopPropagation(); onToggleWatchlist(movie) }}
        title={movie.in_watchlist ? 'Remove from Watchlist' : 'Add to Watchlist'}
      >
        {movie.in_watchlist ? <BookmarkFilled /> : <BookmarkOutline />}
      </button>
    </div>
  )
}

// -- Detail Modal -------------------------------------------------

function DetailModal({ item, onClose, onToggleWatchlist, navigate }) {
  const api = useApi()
  const [loading, setLoading] = useState(true)
  const [detail, setDetail] = useState(null)
  const [activeSeason, setActiveSeason] = useState(null)
  const overlayRef = useRef(null)
  const discoverModalGlass = useGlassConfig('discover-modal')
  const dmCloseGlass = useGlassConfig('dm-close')
  const dmActionGlass = useGlassConfig('dm-action')
  const seasonTabGlass = useGlassConfig('season-tab')

  const isMovie = item._type === 'movie'

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setDetail(null)
    setActiveSeason(null)

    const fetch = async () => {
      try {
        if (isMovie) {
          const data = await api.getMovieDetails(item.imdb_id)
          if (!cancelled) setDetail(data)
        } else {
          const data = await api.getShowDetails(item.tvmaze_id)
          if (!cancelled && data) {
            setDetail(data)
            // Set first season as active
            const seasonNums = Object.keys(data.seasons).map(Number).sort((a, b) => a - b)
            if (seasonNums.length > 0) setActiveSeason(seasonNums[0])
          }
        }
      } catch (err) {
        console.error('Failed to load details:', err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    fetch()

    return () => { cancelled = true }
  }, [item, isMovie, api])

  // Close on Escape
  useEffect(() => {
    const handler = (e) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [onClose])

  // Close on overlay click
  const handleOverlayClick = (e) => {
    if (e.target === overlayRef.current) onClose()
  }

  // Show data: merge item (from search) with fetched detail
  const show = isMovie ? null : (detail?.show || item)
  const movieDetail = isMovie ? detail : null

  const poster = isMovie
    ? (movieDetail?.poster_url || item.poster_url)
    : (show?.poster_url || item.poster_url)
  const title = item.name
  const genres = isMovie
    ? genresList(movieDetail?.genres || item.genres)
    : genresList(show?.genres || item.genres)
  const year = isMovie
    ? (movieDetail?.year || item.year)
    : premiereYear(show?.premiered || item.premiered)
  const rating = isMovie
    ? (movieDetail?.rating || item.rating)
    : (show?.rating || item.rating)
  const description = isMovie
    ? (movieDetail?.description || item.description)
    : (show?.description || item.description)
  const imdbId = isMovie
    ? (movieDetail?.imdb_id || item.imdb_id)
    : (show?.imdb_id || item.imdb_id)
  const status = isMovie ? null : (show?.status || item.status)
  const network = isMovie ? null : (show?.network || item.network)
  const director = isMovie ? (movieDetail?.director || item.director) : null
  const runtime = isMovie
    ? (movieDetail?.runtime || item.runtime)
    : (show?.runtime || item.runtime)

  const seasonNums = detail?.seasons
    ? Object.keys(detail.seasons).map(Number).sort((a, b) => a - b)
    : []
  const seasonEpisodes = activeSeason != null && detail?.seasons
    ? (detail.seasons[activeSeason] || [])
    : []
  const totalEpisodes = detail?.episodes?.length || 0

  return (
    <div className="dm-overlay" ref={overlayRef} onClick={handleOverlayClick}>
      <refractive.div className="dm-container" refraction={discoverModalGlass}>
        {/* Close button */}
        <refractive.button className="dm-close" onClick={onClose} refraction={dmCloseGlass}><CloseSvg /></refractive.button>

        {/* Hero — same style as library show-hero */}
        <header
          className="dm-hero"
          style={poster ? { '--poster': `url(${poster})` } : undefined}
        >
          <div className="dm-hero-bg" />
          <div className="dm-hero-content">
            {poster && (
              <div className="dm-poster">
                <img src={poster} alt={title} />
              </div>
            )}
            <div className="dm-info">
              <h1 className="dm-title">{title}</h1>
              <div className="show-meta-row">
                {year && <span>{year}</span>}
                {status && (
                  <span className={`show-status show-status--${statusClass(status)}`}>{status}</span>
                )}
                {rating && <span className="show-rating">{'\u2605'} {rating}</span>}
                {runtime && <span>{runtime}m</span>}
                {director && <span className="movie-director">Dir. {director}</span>}
                {network && <span>{network}</span>}
                {imdbId && (
                  <a href={`https://www.imdb.com/title/${imdbId}/`} target="_blank" rel="noreferrer" className="show-imdb">IMDb</a>
                )}
              </div>
              {genres.length > 0 && (
                <div className="show-genres">{genres.join('  \u00B7  ')}</div>
              )}
              {description && (
                <p className="show-description">{description}</p>
              )}

              {/* Action buttons in hero */}
              <div className="dm-actions">
                {item.in_library && item.library_slug && (
                  <refractive.button
                    className="dm-library-btn"
                    onClick={() => {
                      onClose()
                      navigate(isMovie ? `/movies/${item.library_slug}` : `/series/${item.library_slug}`)
                    }}
                    refraction={dmActionGlass}
                  >
                    <span className="dm-library-dot" />
                    <span>In Library</span>
                  </refractive.button>
                )}
                <refractive.button
                  className={`dm-watchlist-btn${item.in_watchlist ? ' active' : ''}`}
                  onClick={() => onToggleWatchlist(item)}
                  refraction={dmActionGlass}
                >
                  {item.in_watchlist ? <BookmarkFilled /> : <BookmarkOutline />}
                  <span>{item.in_watchlist ? 'In Watchlist' : 'Add to Watchlist'}</span>
                </refractive.button>
              </div>
            </div>
          </div>
        </header>

        {/* Content below hero */}
        <div className="dm-body">
          {loading && (
            <div className="dm-loading">Loading details...</div>
          )}

          {/* Show: stats + season tabs + episodes */}
          {!isMovie && !loading && detail && (
            <>
              {/* Stats */}
              <div className="stats-row">
                {seasonNums.length > 0 && (
                  <div className="stat"><span className="stat-val">{seasonNums.length}</span><span className="stat-lbl">Seasons</span></div>
                )}
                {totalEpisodes > 0 && (
                  <div className="stat"><span className="stat-val">{totalEpisodes}</span><span className="stat-lbl">Episodes</span></div>
                )}
              </div>

              {/* Season Tabs */}
              {seasonNums.length > 0 && (
                <div className="dm-season-tabs">
                  {seasonNums.map(num => (
                    <refractive.button
                      key={num}
                      className={`dm-season-tab${activeSeason === num ? ' active' : ''}`}
                      onClick={() => setActiveSeason(num)}
                      refraction={seasonTabGlass}
                    >
                      {num === 0 ? 'Specials' : `S${num}`}
                    </refractive.button>
                  ))}
                </div>
              )}

              {/* Episode list */}
              {seasonEpisodes.length > 0 && (
                <div className="dm-episodes">
                  {seasonEpisodes.map(ep => (
                    <div key={ep.tvmaze_id} className="dm-episode">
                      <span className="dm-ep-number">
                        {ep.number != null ? `E${String(ep.number).padStart(2, '0')}` : ''}
                      </span>
                      <div className="dm-ep-info">
                        <span className="dm-ep-name">{ep.name || 'TBA'}</span>
                        <div className="dm-ep-meta">
                          {ep.airdate && <span>{ep.airdate}</span>}
                          {ep.runtime && <span>{ep.runtime}m</span>}
                        </div>
                        {ep.summary && (
                          <p className="dm-ep-summary">{ep.summary}</p>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </>
          )}

          {/* Movie: extra details */}
          {isMovie && !loading && movieDetail && (
            <div className="dm-movie-details">
              {movieDetail.director && (
                <div className="dm-detail-row">
                  <span className="dm-detail-label">Director</span>
                  <span>{movieDetail.director}</span>
                </div>
              )}
              {movieDetail.runtime && (
                <div className="dm-detail-row">
                  <span className="dm-detail-label">Runtime</span>
                  <span>{movieDetail.runtime} min</span>
                </div>
              )}
              {movieDetail.genres && (
                <div className="dm-detail-row">
                  <span className="dm-detail-label">Genres</span>
                  <span>{movieDetail.genres}</span>
                </div>
              )}
            </div>
          )}

          {!loading && !detail && !isMovie && (
            <p className="dm-loading">No additional details available.</p>
          )}
        </div>
      </refractive.div>
    </div>
  )
}

// -- Discover Page ------------------------------------------------

export default function Discover() {
  const navigate = useNavigate()
  const api = useApi()
  const [query, setQuery] = useState('')
  const [searchType, setSearchType] = useState('all') // 'all' | 'shows' | 'movies'
  const [shows, setShows] = useState([])
  const [movies, setMovies] = useState([])
  const [watchlist, setWatchlist] = useState([])
  const [searching, setSearching] = useState(false)
  const [hasSearched, setHasSearched] = useState(false)
  const [modalItem, setModalItem] = useState(null)
  const debounceRef = useRef(null)
  const inputRef = useRef(null)
  const clearBtnGlass = useGlassConfig('clear-btn')
  const filterBtnGlass = useGlassConfig('filter-btn')

  const loadWatchlist = useCallback(async () => {
    try {
      const items = await api.listWatchlist()
      setWatchlist(items)
    } catch (err) {
      console.error('Failed to load watchlist:', err)
    }
  }, [api])

  useEffect(() => { loadWatchlist() }, [loadWatchlist])
  useEffect(() => { inputRef.current?.focus() }, [])

  // Debounced search
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current)

    if (!query.trim() || query.trim().length < 2) {
      setShows([])
      setMovies([])
      setHasSearched(false)
      loadWatchlist()
      return
    }

    debounceRef.current = setTimeout(async () => {
      setSearching(true)
      try {
        const data = await api.searchShows(query, searchType)
        setShows(data.shows || [])
        setMovies(data.movies || [])
        setHasSearched(true)
      } catch (err) {
        console.error('Search failed:', err)
      } finally {
        setSearching(false)
      }
    }, 400)

    return () => { if (debounceRef.current) clearTimeout(debounceRef.current) }
  }, [query, searchType, loadWatchlist])

  const handleClearSearch = () => {
    setQuery('')
    inputRef.current?.focus()
  }

  const handleToggleWatchlist = async (item) => {
    const isMovie = item._type === 'movie'
    if (item.in_watchlist) {
      if (isMovie) {
        await api.removeFromWatchlist({ _type: 'movie', imdb_id: item.imdb_id })
      } else {
        await api.removeFromWatchlist(item.tvmaze_id)
      }
    } else {
      await api.addToWatchlist(item)
    }
    await loadWatchlist()
    // Update search results in place
    if (isMovie) {
      setMovies(prev => prev.map(r =>
        r.imdb_id === item.imdb_id ? { ...r, in_watchlist: !r.in_watchlist } : r
      ))
    } else {
      setShows(prev => prev.map(r =>
        r.tvmaze_id === item.tvmaze_id ? { ...r, in_watchlist: !r.in_watchlist } : r
      ))
    }
    // Update modal item if open
    if (modalItem) {
      const isSame = isMovie
        ? modalItem.imdb_id === item.imdb_id
        : modalItem.tvmaze_id === item.tvmaze_id
      if (isSame) {
        setModalItem(prev => ({ ...prev, in_watchlist: !prev.in_watchlist }))
      }
    }
  }

  const handleCardClick = (item) => {
    setModalItem(item)
  }

  const showingResults = query.trim().length >= 2
  const noResults = hasSearched && shows.length === 0 && movies.length === 0 && !searching

  return (
    <>
      <Navbar active="Discover" />
      <main className="discover-main">
        <h1 className="page-title">Discover</h1>

        <div className="discover-search">
          <input
            ref={inputRef}
            type="text"
            className="discover-search-input"
            placeholder={
              searchType === 'shows' ? 'Search TV shows...'
                : searchType === 'movies' ? 'Search movies...'
                : 'Search TV shows and movies...'
            }
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          {searching && <div className="discover-spinner" />}
          {!searching && query && (
            <refractive.button className="discover-clear-btn" onClick={handleClearSearch} title="Clear search" refraction={clearBtnGlass}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
                <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
              </svg>
            </refractive.button>
          )}
        </div>

        <div className="discover-filters">
          {['all', 'shows', 'movies'].map(type => (
            <refractive.button
              key={type}
              className={`discover-filter-btn${searchType === type ? ' active' : ''}`}
              onClick={() => setSearchType(type)}
              refraction={filterBtnGlass}
            >
              {type === 'all' ? 'All' : type === 'shows' ? 'TV Shows' : 'Movies'}
            </refractive.button>
          ))}
        </div>

        {/* Search Results */}
        {showingResults && (
          <>
            {noResults && (
              <p className="discover-empty">No results found for "{query}"</p>
            )}

            {shows.length > 0 && (
              <section className="discover-section">
                {movies.length > 0 && <h2 className="section-title">TV Shows</h2>}
                <div className="series-grid">
                  {shows.map(show => (
                    <ShowCard
                      key={show.tvmaze_id}
                      show={show}
                      onToggleWatchlist={handleToggleWatchlist}
                      onClick={() => handleCardClick(show)}
                    />
                  ))}
                </div>
              </section>
            )}

            {movies.length > 0 && (
              <section className="discover-section">
                {shows.length > 0 && <h2 className="section-title">Movies</h2>}
                <div className="series-grid">
                  {movies.map(movie => (
                    <MovieCard
                      key={movie.imdb_id}
                      movie={movie}
                      onToggleWatchlist={handleToggleWatchlist}
                      onClick={() => handleCardClick(movie)}
                    />
                  ))}
                </div>
              </section>
            )}
          </>
        )}

        {/* Watchlist (when not searching) */}
        {!showingResults && watchlist.length > 0 && (
          <section className="discover-section">
            <h2 className="section-title">Watchlist</h2>
            <div className="series-grid">
              {watchlist.map(item => (
                item._type === 'movie' ? (
                  <MovieCard
                    key={`wl-movie-${item.imdb_id}`}
                    movie={item}
                    onToggleWatchlist={handleToggleWatchlist}
                    onClick={() => handleCardClick(item)}
                  />
                ) : (
                  <ShowCard
                    key={`wl-show-${item.tvmaze_id}`}
                    show={item}
                    onToggleWatchlist={handleToggleWatchlist}
                    onClick={() => handleCardClick(item)}
                  />
                )
              ))}
            </div>
          </section>
        )}

        {/* Empty state */}
        {!showingResults && watchlist.length === 0 && (
          <div className="discover-empty-hero">
            <div className="discover-empty-icon">
              <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
                <circle cx="11" cy="11" r="8" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
            </div>
            <p>Search for TV shows and movies to discover something new.</p>
            <p className="discover-empty-sub">Shows and movies you save will appear here in your watchlist.</p>
          </div>
        )}
      </main>

      {/* Detail Modal */}
      {modalItem && (
        <DetailModal
          item={modalItem}
          onClose={() => setModalItem(null)}
          onToggleWatchlist={handleToggleWatchlist}
          navigate={navigate}
        />
      )}
    </>
  )
}
