// Fetches movie metadata from imdbapi.dev.
// No API key required, no known rate limit.

const db = require('../db')
const path = require('path')

const BASE_URL = 'https://api.imdbapi.dev'

// Extract a clean movie name from a filename
function nameFromFilename(filename) {
  let name = path.basename(filename, path.extname(filename))

  // Strip parenthesized year and everything after
  let clean = name.replace(/\s*\(\d{4}\).*/, '')
  if (clean !== name && clean.trim()) return clean.trim()

  // Strip dot-separated year (19xx/20xx) and everything after
  clean = name.replace(/[.](?:19|20)\d{2}.*/, '')
  if (clean !== name && clean.trim()) return clean.replace(/\./g, ' ').trim()

  // Strip quality markers
  clean = name.replace(/[.\s](?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN).*$/i, '')
  clean = clean.replace(/\./g, ' ').trim()
  return clean || name
}

// Extract year from filename
function yearFromFilename(filename) {
  let m = filename.match(/\((\d{4})\)/)
  if (m) return m[1]
  m = filename.match(/[.\s]((?:19|20)\d{2})[.\s]/)
  if (m) return m[1]
  return null
}

async function searchTitle(title) {
  const url = `${BASE_URL}/search/titles?query=${encodeURIComponent(title)}&limit=1`
  try {
    const res = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    })
    if (res.status === 429) {
      const retryAfter = parseInt(res.headers.get('retry-after') || '10', 10)
      console.warn(`MovieMetadata: rate limited, retrying after ${retryAfter}s`)
      await new Promise(r => setTimeout(r, retryAfter * 1000))
      return searchTitle(title) // single retry
    }
    if (!res.ok) return null
    const data = await res.json()
    // Basic response validation
    if (!data || typeof data !== 'object') return null
    const titles = data.titles
    if (!Array.isArray(titles) || titles.length === 0) return null
    return titles.find(t => t.type === 'movie') || titles[0]
  } catch (e) {
    console.warn(`MovieMetadata: search failed for '${title}' — ${e.message}`)
    return null
  }
}

async function getTitleDetails(imdbId) {
  const url = `${BASE_URL}/titles/${imdbId}`
  try {
    const res = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    })
    if (res.status === 429) {
      const retryAfter = parseInt(res.headers.get('retry-after') || '10', 10)
      console.warn(`MovieMetadata: rate limited, retrying after ${retryAfter}s`)
      await new Promise(r => setTimeout(r, retryAfter * 1000))
      return getTitleDetails(imdbId) // single retry
    }
    if (!res.ok) return null
    const data = await res.json()
    // Basic response validation — expect an object with an id
    if (!data || typeof data !== 'object' || !data.id) return null
    return data
  } catch (e) {
    console.warn(`MovieMetadata: get_title failed for '${imdbId}' — ${e.message}`)
    return null
  }
}

async function fetchForMovie(movieId) {
  const movie = db.movies.findById(movieId)
  if (!movie) return false

  const result = await searchTitle(movie.title)
  if (!result) return false

  const data = await getTitleDetails(result.id)
  if (!data) return false

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
    attrs.director = data.directors.map(d => d.displayName).filter(Boolean).join(', ')
  }
  if (data.runtimeSeconds && parseInt(data.runtimeSeconds) > 0) {
    attrs.runtime = Math.round(parseInt(data.runtimeSeconds) / 60)
  }

  if (Object.keys(attrs).length > 0) {
    db.movies.update(movieId, attrs)
  }

  console.log(`MovieMetadata: updated '${movie.title}' (IMDb: ${data.id})`)
  return true
}

module.exports = { fetchForMovie, nameFromFilename, yearFromFilename }
