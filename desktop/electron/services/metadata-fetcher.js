// Fetches TV show metadata from TVMaze API.
// No API key needed. Rate limit: 20 calls/10s.

const db = require('../db')

const BASE_URL = 'https://api.tvmaze.com'

function stripHtml(html) {
  if (!html) return null
  let text = html.replace(/<[^>]+>/g, '')
  text = text.replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
  return text.trim() || null
}

async function search(query) {
  const url = `${BASE_URL}/singlesearch/shows?q=${encodeURIComponent(query)}&embed=episodes`
  try {
    const res = await fetch(url, {
      headers: { Accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    })
    // Handle rate limiting (TVMaze: 20 calls/10s)
    if (res.status === 429) {
      const retryAfter = parseInt(res.headers.get('retry-after') || '10', 10)
      console.warn(`MetadataFetcher: rate limited, retrying after ${retryAfter}s`)
      await new Promise(r => setTimeout(r, retryAfter * 1000))
      return search(query) // single retry
    }
    if (!res.ok) return null
    const data = await res.json()
    // Basic response validation — expect an object with an id
    if (!data || typeof data !== 'object' || !data.id) return null
    return data
  } catch (e) {
    console.warn(`MetadataFetcher: search failed for '${query}' — ${e.message}`)
    return null
  }
}

async function fetchForShow(showId) {
  const s = db.shows.findById(showId)
  if (!s) return false

  const data = await search(s.name)
  if (!data) return false

  // Update show metadata
  const posterUrl = data.image?.original || data.image?.medium || null
  const summary = stripHtml(data.summary)

  db.shows.update(showId, {
    tvmaze_id: data.id,
    poster_url: posterUrl,
    description: summary,
    genres: Array.isArray(data.genres) ? data.genres.join(', ') : null,
    rating: data.rating?.average || null,
    premiered: data.premiered || null,
    status: data.status || null,
    imdb_id: data.externals?.imdb || null,
  })

  // Update episode metadata
  const apiEpisodes = data._embedded?.episodes || []
  if (apiEpisodes.length > 0) {
    const apiLookup = {}
    for (const ep of apiEpisodes) {
      if (ep.season == null || ep.number == null) continue
      const code = `S${String(ep.season).padStart(2, '0')}E${String(ep.number).padStart(2, '0')}`
      apiLookup[code] = ep
    }

    const localEpisodes = db.episodes.forShow(showId)
    let matched = 0
    for (const episode of localEpisodes) {
      const apiEp = apiLookup[episode.code]
      if (!apiEp) continue

      const attrs = {}
      const epSummary = stripHtml(apiEp.summary)
      if (epSummary) attrs.description = epSummary
      if (apiEp.airdate) attrs.air_date = apiEp.airdate
      if (apiEp.runtime) attrs.runtime = apiEp.runtime
      if (apiEp.id) attrs.tvmaze_id = apiEp.id

      if (Object.keys(attrs).length > 0) {
        db.episodes.updateMetadata(episode.id, attrs)
        matched++
      }
    }
    console.log(`MetadataFetcher: matched ${matched}/${localEpisodes.length} episodes with TVMaze data`)
  }

  console.log(`MetadataFetcher: updated show '${s.name}' (TVMaze ID: ${data.id})`)
  return true
}

module.exports = { fetchForShow, search }
