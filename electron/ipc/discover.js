// IPC handlers for Discover (TVMaze + imdbapi.dev search, watchlist)

const { ipcMain, net } = require('electron')
const db = require('../db')

const IMDB_API = 'https://api.imdbapi.dev'

function stripHtml(html) {
  if (!html) return ''
  return html.replace(/<[^>]+>/g, '').trim()
}

function mapShow(show) {
  return {
    _type: 'show',
    tvmaze_id: show.id,
    name: show.name,
    poster_url: show.image?.original || show.image?.medium || null,
    description: stripHtml(show.summary),
    genres: (show.genres || []).join(', '),
    rating: show.rating?.average || null,
    premiered: show.premiered || null,
    status: show.status || null,
    network: show.network?.name || show.webChannel?.name || null,
    imdb_id: show.externals?.imdb || null,
    type: show.type || null,
    language: show.language || null,
    runtime: show.runtime || show.averageRuntime || null,
    schedule: show.schedule || null,
    officialSite: show.officialSite || null,
  }
}

function mapMovie(title) {
  return {
    _type: 'movie',
    imdb_id: title.id || null,
    name: title.primaryTitle || title.originalTitle || 'Unknown',
    poster_url: title.primaryImage?.url || null,
    year: title.startYear ? String(title.startYear) : null,
    rating: title.rating?.aggregateRating || null,
  }
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const request = net.request(url)
    let body = ''
    request.on('response', (response) => {
      if (response.statusCode === 404) { resolve(null); return }
      if (response.statusCode !== 200) { reject(new Error(`HTTP ${response.statusCode}`)); return }
      response.on('data', (chunk) => { body += chunk.toString() })
      response.on('end', () => {
        try { resolve(JSON.parse(body)) }
        catch (e) { reject(e) }
      })
    })
    request.on('error', reject)
    request.end()
  })
}

function register() {
  // Combined search: TVMaze (shows) + imdbapi.dev (movies) in parallel
  // searchType: 'all' (default), 'shows', 'movies'
  ipcMain.handle('discover:search', async (_e, query, searchType) => {
    if (!query || query.trim().length < 2) return { shows: [], movies: [] }

    const q = query.trim()
    const type = searchType || 'all'

    const promises = []
    const indices = { shows: -1, movies: -1 }
    let idx = 0

    if (type === 'all' || type === 'shows') {
      indices.shows = idx++
      promises.push(fetchJson(`https://api.tvmaze.com/search/shows?q=${encodeURIComponent(q)}`))
    }
    if (type === 'all' || type === 'movies') {
      indices.movies = idx++
      promises.push(fetchJson(`${IMDB_API}/search/titles?query=${encodeURIComponent(q)}&limit=10`))
    }

    const results = await Promise.allSettled(promises)

    // -- TV Shows --
    let shows = []
    if (indices.shows >= 0) {
      const showResult = results[indices.shows]
      if (showResult.status === 'fulfilled' && Array.isArray(showResult.value)) {
        const librarySeries = db.series.all()
        const librarySlugByTvmazeId = new Map(
          librarySeries.filter(s => s.tvmaze_id).map(s => [s.tvmaze_id, s.slug])
        )
        const watchlistIds = new Set(
          db.watchlist.all().filter(w => w.type !== 'movie').map(w => w.tvmaze_id).filter(Boolean)
        )
        shows = showResult.value.map(r => {
          const show = mapShow(r.show)
          show.score = r.score
          show.in_library = librarySlugByTvmazeId.has(show.tvmaze_id)
          show.library_slug = librarySlugByTvmazeId.get(show.tvmaze_id) || null
          show.in_watchlist = watchlistIds.has(show.tvmaze_id)
          return show
        })
      }
    }

    // -- Movies --
    let movies = []
    if (indices.movies >= 0) {
      const movieResult = results[indices.movies]
      if (movieResult.status === 'fulfilled' && movieResult.value?.titles) {
        const libraryMovies = db.movies.all()
        const librarySlugByImdbId = new Map(
          libraryMovies.filter(m => m.imdb_id).map(m => [m.imdb_id, m.slug])
        )
        const watchlistImdbIds = new Set(
          db.watchlist.all().filter(w => w.type === 'movie').map(w => w.imdb_id).filter(Boolean)
        )
        movies = movieResult.value.titles
          .filter(t => t.type === 'movie')
          .map(t => {
            const movie = mapMovie(t)
            movie.in_library = librarySlugByImdbId.has(movie.imdb_id)
            movie.library_slug = librarySlugByImdbId.get(movie.imdb_id) || null
            movie.in_watchlist = watchlistImdbIds.has(movie.imdb_id)
            return movie
          })
      }
    }

    return { shows, movies }
  })

  // Fetch full show details + episodes from TVMaze (on-demand, when modal opens)
  ipcMain.handle('discover:showDetails', async (_e, tvmazeId) => {
    if (!tvmazeId) return null
    try {
      const data = await fetchJson(`https://api.tvmaze.com/shows/${tvmazeId}?embed=episodes`)
      if (!data) return null

      const show = mapShow(data)
      const episodes = (data._embedded?.episodes || []).map(ep => ({
        tvmaze_id: ep.id,
        season: ep.season,
        number: ep.number,
        name: ep.name || null,
        airdate: ep.airdate || null,
        runtime: ep.runtime || null,
        summary: stripHtml(ep.summary),
      }))

      // Group episodes by season
      const seasons = {}
      for (const ep of episodes) {
        const s = ep.season
        if (!seasons[s]) seasons[s] = []
        seasons[s].push(ep)
      }

      return { show, episodes, seasons }
    } catch (e) {
      console.warn(`Discover: showDetails failed for ${tvmazeId} — ${e.message}`)
      return null
    }
  })

  // Fetch full movie details from imdbapi.dev (on-demand, when card is expanded)
  ipcMain.handle('discover:movieDetails', async (_e, imdbId) => {
    if (!imdbId) return null
    try {
      const data = await fetchJson(`${IMDB_API}/titles/${imdbId}`)
      if (!data) return null
      return {
        imdb_id: data.id,
        description: data.plot || null,
        genres: Array.isArray(data.genres) ? data.genres.join(', ') : null,
        director: Array.isArray(data.directors)
          ? data.directors.map(d => d.displayName).filter(Boolean).join(', ')
          : null,
        runtime: data.runtimeSeconds ? Math.round(parseInt(data.runtimeSeconds) / 60) : null,
        year: data.startYear ? String(data.startYear) : null,
        rating: data.rating?.aggregateRating || null,
        poster_url: data.primaryImage?.url || null,
      }
    } catch (e) {
      console.warn(`Discover: movieDetails failed for ${imdbId} — ${e.message}`)
      return null
    }
  })

  // Add show or movie to watchlist
  ipcMain.handle('discover:addToWatchlist', async (_e, item) => {
    if (!item) return { error: 'Invalid data' }
    if (item._type === 'movie') {
      if (!item.imdb_id) return { error: 'Invalid movie data — missing imdb_id' }
      const result = db.watchlist.addMovie(item)
      return result ? { success: true } : { error: 'Failed to add movie to watchlist' }
    } else {
      if (!item.tvmaze_id) return { error: 'Invalid show data — missing tvmaze_id' }
      const result = db.watchlist.addShow(item)
      return result ? { success: true } : { error: 'Failed to add show to watchlist' }
    }
  })

  // Remove show or movie from watchlist
  ipcMain.handle('discover:removeFromWatchlist', async (_e, identifier) => {
    if (!identifier) return { error: 'Invalid identifier' }
    // Accept either a number (legacy tvmaze_id) or { type, tvmaze_id, imdb_id }
    if (typeof identifier === 'number') {
      db.watchlist.removeByTvmazeId(identifier)
    } else if (typeof identifier === 'object') {
      if (identifier.type === 'movie' || identifier._type === 'movie') {
        db.watchlist.removeByImdbId(identifier.imdb_id)
      } else {
        db.watchlist.removeByTvmazeId(identifier.tvmaze_id)
      }
    } else if (typeof identifier === 'string') {
      db.watchlist.removeByImdbId(identifier)
    }
    return { success: true }
  })

  // List watchlist with in_library flags (shows + movies)
  ipcMain.handle('discover:listWatchlist', async () => {
    const items = db.watchlist.all()
    const librarySeries = db.series.all()
    const librarySlugByTvmazeId = new Map(
      librarySeries.filter(s => s.tvmaze_id).map(s => [s.tvmaze_id, s.slug])
    )
    const libraryMovies = db.movies.all()
    const librarySlugByImdbId = new Map(
      libraryMovies.filter(m => m.imdb_id).map(m => [m.imdb_id, m.slug])
    )
    return items.map(item => {
      const isMovie = item.type === 'movie'
      return {
        ...item,
        _type: item.type || 'show',
        in_library: isMovie
          ? librarySlugByImdbId.has(item.imdb_id)
          : librarySlugByTvmazeId.has(item.tvmaze_id),
        library_slug: isMovie
          ? (librarySlugByImdbId.get(item.imdb_id) || null)
          : (librarySlugByTvmazeId.get(item.tvmaze_id) || null),
        in_watchlist: true,
      }
    })
  })
}

module.exports = { register }
