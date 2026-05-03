// Scans a show's media directory for episode files.
// Mirrors server/app/services/media_scanner_service.rb. Filename / episode
// parsing is delegated to filename-parser.js (the Jellyfin-style chained
// parser). Public surface preserved for existing callers:
//   nameFromPath, parseEpisode, collectMkvFiles, scan, addFromPath

const fs = require('fs')
const path = require('path')
const db = require('../db')
const parser = require('./filename-parser')
const nfo = require('./nfo-parser')
const techProbe = require('./tech-probe')

function nameFromPath(folderPath) {
  const folder = path.basename(folderPath || '')
  const parsed = parser.parse(folder)
  if (parsed.title && parsed.title !== folder) return parsed.title
  return folder.replace(/\./g, ' ').trim() || folder
}

function isSeasonDir(name) {
  return parser.seasonFromFolder(name) != null
}

function safeReaddir(dir) {
  try { return fs.readdirSync(dir) } catch { return [] }
}

function isFile(p) {
  try { return fs.statSync(p).isFile() } catch { return false }
}

function isDirectory(p) {
  try { return fs.statSync(p).isDirectory() } catch { return false }
}

function collectFromDir(dir) {
  const files = []
  const entries = safeReaddir(dir)

  for (const entry of entries) {
    if (entry.startsWith('.')) continue
    const dirPath = path.join(dir, entry)
    if (!isDirectory(dirPath)) continue
    if (!isSeasonDir(entry)) continue

    for (const f of safeReaddir(dirPath)) {
      const full = path.join(dirPath, f)
      if (parser.videoFile(f) && isFile(full)) {
        files.push([full, f])
      }
    }
  }

  for (const f of entries) {
    const full = path.join(dir, f)
    if (parser.videoFile(f) && isFile(full)) {
      files.push([full, f])
    }
  }

  return files
}

function collectMkvFiles(mediaRoot) {
  let files = collectFromDir(mediaRoot)

  if (files.length === 0) {
    for (const entry of safeReaddir(mediaRoot)) {
      if (entry.startsWith('.')) continue
      const subdir = path.join(mediaRoot, entry)
      if (!isDirectory(subdir)) continue
      if (isSeasonDir(entry)) continue
      const nested = collectFromDir(subdir)
      if (nested.length > 0) {
        files = nested
        break
      }
    }
  }

  return files.sort((a, b) => a[1].localeCompare(b[1]))
}

function seasonFromPath(fullPath) {
  return parser.seasonFromFolder(path.basename(path.dirname(fullPath)))
}

// Extract a human episode title from the part of the filename after the
// SxxExx code. Independent of filename-parser — this one is for display
// titles, the parser is for identifiers.
function extractTitle(filename) {
  const m = filename.match(/S(\d{1,3})E(\d{1,3})/i)
  if (!m) return null
  const afterCode = filename.slice(m.index + m[0].length)

  if (/^\s*-\s*/.test(afterCode)) {
    let title = afterCode.replace(/^\s*-\s*/, '')
    title = title.replace(/\s*\([^)]*\)\s*\.\w+$/i, '')
    title = title.replace(/\.\w+$/i, '')
    return title.trim() || null
  }

  if (/^\./.test(afterCode)) {
    let title = afterCode.replace(/^\./, '')
    title = title.replace(/\.\w+$/i, '')
    title = title.replace(/\.(?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN|REPACK).*$/i, '')
    title = title.replace(/\./g, ' ').trim()
    if (/^\d{3,4}p$/i.test(title)) return null
    return title || null
  }
  return null
}

function parseEpisode(filename) {
  const parsed = parser.parse(filename)
  if (parsed.type !== 'episode' || !parsed.episode) return null
  const season = parsed.season || 1
  const episode = parsed.episode
  const code = `S${String(season).padStart(2, '0')}E${String(episode).padStart(2, '0')}`
  const title = extractTitle(filename) || code
  return { season, episode, title, code }
}

function scan(showId) {
  const s = db.shows.findById(showId)
  if (!s) return 0

  if (!fs.existsSync(s.media_path)) {
    console.warn(`MediaScanner: media root not found: ${s.media_path}`)
    return 0
  }

  const files = collectMkvFiles(s.media_path)
  let count = 0

  for (const [fullPath, filename] of files) {
    const parsed = parser.parse(filename)
    if (parsed.is_extra) continue
    if (parsed.type !== 'episode' || !parsed.episode) continue

    const season = parsed.season || seasonFromPath(fullPath) || 1
    const episode = parsed.episode
    const code = `S${String(season).padStart(2, '0')}E${String(episode).padStart(2, '0')}`
    const title = extractTitle(filename) || code

    const upserted = db.episodes.upsert({
      show_id: showId,
      code,
      title,
      season_number: season,
      episode_number: episode,
      file_path: fullPath,
    })
    count++

    // Background probe — fire-and-forget; cached on the row when done.
    const epId = upserted && upserted.id
    if (epId) {
      techProbe.probeAndCache('episodes', epId).catch(() => {})
    }
  }

  console.log(`MediaScanner: scanned ${count} episodes for '${s.name}'`)
  return count
}

async function addFromPath(folderPath, fetchMetadata) {
  folderPath = folderPath.trim()

  // Local-first: NFO sidecar + filename ID extraction seed metadata
  // before any remote API call.
  const nfoData = nfo.readShow(folderPath) || {}
  const filenameIds = parser.extractProviderIds(folderPath)
  const imdbId = nfoData.imdb_id || filenameIds.imdb || null

  const name = nfoData.title || nameFromPath(folderPath)

  let s = db.shows.findByMediaPath(folderPath)
  if (!s) {
    s = db.shows.create({ name, media_path: folderPath, imdb_id: imdbId })
  } else if (imdbId && !s.imdb_id) {
    db.shows.update(s.id, { imdb_id: imdbId })
  }

  scan(s.id)

  if (fetchMetadata) {
    await fetchMetadata(s, { imdbId })
  }

  return db.shows.findById(s.id)
}

module.exports = { scan, addFromPath, nameFromPath, parseEpisode, collectMkvFiles }
