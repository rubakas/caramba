// Reads Kodi-style .nfo XML sidecars next to media files.
// Mirror of server/app/services/nfo_parser_service.rb.
//
// We avoid pulling in a full XML parser dep — Kodi NFOs have a small,
// fixed tag vocabulary, so regex extraction is simpler and matches what
// 99% of tools (Plex, Emby, Jellyfin, Sonarr) generate. Falls back
// silently on malformed XML.
//
// Public API:
//   readShow(mediaPath)   -> attrs | null  (looks for tvshow.nfo)
//   readMovie(filePath)   -> attrs | null  (looks for <basename>.nfo or movie.nfo)
//   readEpisode(filePath) -> attrs | null  (looks for <basename>.nfo)

const fs = require('fs')
const path = require('path')

const ROOT_TAGS = {
  show: ['tvshow'],
  movie: ['movie'],
  episode: ['episodedetails', 'episode'],
}

function readShow(mediaPath) {
  if (!mediaPath || !fs.existsSync(mediaPath)) return null
  const nfo = path.join(mediaPath, 'tvshow.nfo')
  if (!fs.existsSync(nfo)) return null
  return parseFile(nfo, 'show')
}

function readMovie(filePath) {
  if (!filePath) return null
  const nfo = locateSidecar(filePath, 'movie.nfo')
  return nfo ? parseFile(nfo, 'movie') : null
}

function readEpisode(filePath) {
  if (!filePath) return null
  const base = path.basename(filePath, path.extname(filePath))
  const candidate = path.join(path.dirname(filePath), `${base}.nfo`)
  if (!fs.existsSync(candidate)) return null
  return parseFile(candidate, 'episode')
}

function locateSidecar(filePath, sidecarName) {
  const base = path.basename(filePath, path.extname(filePath))
  const dir = path.dirname(filePath)
  const sibling = path.join(dir, `${base}.nfo`)
  if (fs.existsSync(sibling)) return sibling
  const generic = path.join(dir, sidecarName)
  if (fs.existsSync(generic)) return generic
  return null
}

function truncateToRoot(raw, rootTags) {
  for (const tag of rootTags) {
    const idx = raw.indexOf(`</${tag}>`)
    if (idx >= 0) return raw.slice(0, idx + tag.length + 3)
  }
  return raw
}

function parseFile(filePath, kind) {
  let raw
  try {
    raw = fs.readFileSync(filePath, 'utf-8')
  } catch (e) {
    console.warn(`[NfoParser] read failed ${filePath}: ${e.message}`)
    return null
  }
  const truncated = truncateToRoot(raw, ROOT_TAGS[kind])
  return buildAttrs(truncated, kind)
}

function tag(xml, name) {
  const m = xml.match(new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)</${name}>`, 'i'))
  return m ? decodeEntities(stripHtml(m[1].trim())) : null
}

function tagAll(xml, name) {
  const re = new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)</${name}>`, 'gi')
  const out = []
  let m
  while ((m = re.exec(xml)) !== null) {
    const v = decodeEntities(stripHtml(m[1].trim()))
    if (v) out.push(v)
  }
  return out
}

function stripHtml(s) {
  return s.replace(/<[^>]+>/g, '')
}

function decodeEntities(s) {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
}

function extractProviderIds(xml) {
  const ids = {}
  ids.imdb = tag(xml, 'imdbid') || tag(xml, 'imdb_id')
  ids.tmdb = tag(xml, 'tmdbid') || tag(xml, 'tmdb_id')
  ids.tvdb = tag(xml, 'tvdbid') || tag(xml, 'tvdb_id')
  ids.tvmaze = tag(xml, 'tvmazeid') || tag(xml, 'tvmaze_id')

  // <uniqueid type="imdb">tt1234567</uniqueid>
  const re = /<uniqueid\s+type=["']?([a-zA-Z0-9_]+)["']?[^>]*>([^<]+)<\/uniqueid>/gi
  let m
  while ((m = re.exec(xml)) !== null) {
    const t = m[1].toLowerCase()
    const v = (m[2] || '').trim()
    if (!v) continue
    if (t === 'imdb' && !ids.imdb) ids.imdb = v
    if (t === 'tmdb' && !ids.tmdb) ids.tmdb = v
    if (t === 'tvdb' && !ids.tvdb) ids.tvdb = v
    if (t === 'tvmaze' && !ids.tvmaze) ids.tvmaze = v
  }

  Object.keys(ids).forEach((k) => { if (!ids[k]) delete ids[k] })
  return ids
}

function buildAttrs(xml, kind) {
  const attrs = {}
  const title = tag(xml, 'title') || tag(xml, 'originaltitle')
  if (title) attrs.title = title

  const plot = tag(xml, 'plot') || tag(xml, 'outline')
  if (plot) attrs.description = plot

  const year = tag(xml, 'year')
  if (year) attrs.year = year

  const premiered = tag(xml, 'premiered') || tag(xml, 'aired') || tag(xml, 'releasedate')
  if (premiered) {
    attrs.premiered = premiered
    if (kind === 'episode') attrs.air_date = premiered
  }

  const runtime = tag(xml, 'runtime')
  if (runtime && parseInt(runtime, 10) > 0) attrs.runtime = parseInt(runtime, 10)

  const rating = tag(xml, 'rating')
  if (rating) {
    const r = parseFloat(rating)
    if (!Number.isNaN(r)) attrs.rating = r
  }

  const genres = tagAll(xml, 'genre')
  if (genres.length) attrs.genres = genres.join(', ')

  const directors = tagAll(xml, 'director')
  if (directors.length) attrs.director = directors.join(', ')

  if (kind === 'episode') {
    const season = tag(xml, 'season')
    if (season) attrs.season_number = parseInt(season, 10)
    const episode = tag(xml, 'episode')
    if (episode) attrs.episode_number = parseInt(episode, 10)
  }

  attrs.provider_ids = extractProviderIds(xml)
  if (attrs.provider_ids.imdb) attrs.imdb_id = attrs.provider_ids.imdb
  if (attrs.provider_ids.tvmaze) attrs.tvmaze_id = parseInt(attrs.provider_ids.tvmaze, 10)

  return attrs
}

module.exports = { readShow, readMovie, readEpisode }
