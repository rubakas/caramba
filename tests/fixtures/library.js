async function probeFirstShow(apiBase) {
  const res = await fetch(`${apiBase}/api/shows`)
  if (!res.ok) throw new Error(`GET /api/shows failed with ${res.status}`)
  const shows = await res.json()
  if (!shows.length) throw new Error('Library has no shows — add at least one to dev DB')
  return shows[0]
}

async function probeFirstMovie(apiBase) {
  const res = await fetch(`${apiBase}/api/movies`)
  if (!res.ok) throw new Error(`GET /api/movies failed with ${res.status}`)
  const movies = await res.json()
  if (!movies.length) throw new Error('Library has no movies — add at least one to dev DB')
  return movies[0]
}

async function probeFirstEpisode(apiBase) {
  const show = await probeFirstShow(apiBase)
  const res = await fetch(`${apiBase}/api/shows/${show.slug}/full`)
  if (!res.ok) throw new Error(`GET /api/shows/${show.slug}/full failed with ${res.status}`)
  const full = await res.json()
  // /api/shows/:slug/full returns { episodes: [flat], seasons: [int...] }
  // (see server/app/controllers/api/shows_controller.rb).
  const ep = (full.episodes || []).find(e => e.file_path || e.filePath)
  if (!ep) throw new Error(`Show ${show.slug} has no episodes with file paths`)
  return { ...ep, showSlug: show.slug }
}

// Look up an episode by id and return its show slug.
// There is no GET /api/episodes/:id, so we scan /api/shows then /api/shows/:slug/full.
async function probeEpisode(apiBase, id) {
  const numericId = Number(id)
  const showsRes = await fetch(`${apiBase}/api/shows`)
  if (!showsRes.ok) throw new Error(`GET /api/shows failed with ${showsRes.status}`)
  const shows = await showsRes.json()
  for (const show of shows) {
    const fullRes = await fetch(`${apiBase}/api/shows/${show.slug}/full`)
    if (!fullRes.ok) continue
    const full = await fullRes.json()
    const ep = (full.episodes || []).find(e => e.id === numericId)
    if (ep) return { ...ep, showSlug: show.slug }
  }
  throw new Error(`No episode with id=${id} found in any show`)
}

module.exports = { probeFirstShow, probeFirstMovie, probeFirstEpisode, probeEpisode }
