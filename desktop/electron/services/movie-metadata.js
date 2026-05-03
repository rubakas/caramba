// Fetches movie metadata from imdbapi.dev.
// No API key required, no known rate limit.
//
// Filename / year extraction is delegated to filename-parser.js — same
// chained Jellyfin-style parser the show scanner uses. NFO sidecars
// (movie.nfo / <basename>.nfo) seed metadata first; if an IMDb id is on
// disk we go straight to /titles/{id} instead of fuzzy-searching by
// title.

const db = require('../db')
const parser = require('./filename-parser')
const nfo = require('./nfo-parser')
const techProbe = require('./tech-probe')

const BASE_URL = 'https://api.imdbapi.dev'

function nameFromFilename(filename) {
  return parser.nameFromFilename(filename)
}

function yearFromFilename(filename) {
  return parser.yearFromFilename(filename)
}

async function getJson(url) {
  try {
    const res = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    })
    if (res.status === 429) {
      const retryAfter = parseInt(res.headers.get('retry-after') || '10', 10)
      console.warn(`MovieMetadata: rate limited, retrying after ${retryAfter}s`)
      await new Promise(r => setTimeout(r, retryAfter * 1000))
      return getJson(url)
    }
    if (!res.ok) return null
    return await res.json()
  } catch (e) {
    console.warn(`MovieMetadata: HTTP failed for ${url} — ${e.message}`)
    return null
  }
}

async function searchTitle(title) {
  const data = await getJson(`${BASE_URL}/search/titles?query=${encodeURIComponent(title)}&limit=1`)
  if (!data || !Array.isArray(data.titles) || !data.titles.length) return null
  return data.titles.find((t) => t.type === 'movie') || data.titles[0]
}

async function getTitleDetails(imdbId) {
  const data = await getJson(`${BASE_URL}/titles/${imdbId}`)
  if (!data || typeof data !== 'object' || !data.id) return null
  return data
}

function applyData(movieId, movie, data) {
  const attrs = {}
  if (data.primaryImage?.url) attrs.poster_url = data.primaryImage.url
  if (data.plot) attrs.description = data.plot
  if (data.startYear) attrs.year = String(data.startYear)
  if (data.id) attrs.imdb_id = data.id
  if (Array.isArray(data.genres) && data.genres.length > 0) {
    attrs.genres = data.genres.join(', ')
  }
  if (data.rating?.aggregateRating) attrs.rating = parseFloat(data.rating.aggregateRating)
  if (Array.isArray(data.directors) && data.directors.length > 0) {
    attrs.director = data.directors.map((d) => d.displayName).filter(Boolean).join(', ')
  }
  if (data.runtimeSeconds && parseInt(data.runtimeSeconds, 10) > 0) {
    attrs.runtime = Math.round(parseInt(data.runtimeSeconds, 10) / 60)
  }
  if (Object.keys(attrs).length > 0) {
    db.movies.update(movieId, attrs)
  }
  console.log(`MovieMetadata: updated '${movie.title}' (IMDb: ${data.id})`)
  return true
}

async function fetchForMovie(movieId, opts = {}) {
  const movie = db.movies.findById(movieId)
  if (!movie) return false

  // Local-first: NFO sidecar + filename-embedded id.
  const nfoData = nfo.readMovie(movie.file_path) || {}
  const filenameIds = parser.extractProviderIds(movie.file_path || '')
  const imdbId = opts.imdbId || nfoData.imdb_id || filenameIds.imdb || movie.imdb_id

  let data = null
  if (imdbId) data = await getTitleDetails(imdbId)
  if (!data) {
    const result = await searchTitle(movie.title)
    if (result) data = await getTitleDetails(result.id)
  }
  if (!data) return false

  applyData(movieId, movie, data)

  // Background probe — caches codec/duration/resolution.
  techProbe.probeAndCache('movies', movieId).catch(() => {})

  return true
}

module.exports = { fetchForMovie, nameFromFilename, yearFromFilename }
