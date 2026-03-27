// Scans a series' media directory for episode files.
// Supports dot-separated (scene), space+hyphen (Plex), and flat structures.
// Also handles "release folder" nesting (one level deep).

const fs = require('fs')
const path = require('path')
const db = require('../db')

const EPISODE_CODE_RE = /S(\d{1,2})E(\d{1,2})/i

// Derive a clean series name from a folder path.
function nameFromPath(folderPath) {
  let folder = path.basename(folderPath)
  let clean = folder

  // Strip parenthesized year and everything after: "Black Books (2000) Season..." -> "Black Books"
  let stripped = clean.replace(/\s*\(\d{4}\).*/, '')
  if (stripped !== clean && stripped.trim()) return stripped.trim()

  // Strip dot-separated year and everything after: "The.Simpsons.1989..." -> "The.Simpsons"
  stripped = clean.replace(/[.](?:19|20)\d{2}.*/, '')
  if (stripped !== clean && stripped.trim()) {
    return stripped.replace(/\./g, ' ').trim()
  }

  // Strip season code and everything after: "The.City.And.The.City.S01..." -> "The.City.And.The.City"
  stripped = clean.replace(/[.\s]S\d+.*/i, '')
  if (stripped !== clean && stripped.trim()) {
    return stripped.replace(/\./g, ' ').trim()
  }

  return clean.replace(/\./g, ' ').trim() || folder
}

// Check if a directory name is a season directory
function isSeasonDir(name) {
  return /^season\s*\d+$/i.test(name) ||
    /^S\d+$/i.test(name) ||
    /\.S\d+\./i.test(name) ||
    /^specials?$/i.test(name)
}

// Collect MKV files from a directory (season subdirs + root-level)
function collectFromDir(dir) {
  const files = []
  let entries
  try { entries = fs.readdirSync(dir) } catch { return files }

  for (const entry of entries) {
    if (entry.startsWith('.')) continue
    const dirPath = path.join(dir, entry)
    try {
      if (!fs.statSync(dirPath).isDirectory()) continue
    } catch { continue }
    if (!isSeasonDir(entry)) continue

    let subEntries
    try { subEntries = fs.readdirSync(dirPath) } catch { continue }
    for (const f of subEntries) {
      if (f.toLowerCase().endsWith('.mkv')) {
        files.push([path.join(dirPath, f), f])
      }
    }
  }

  // Also check root for MKV files (flat structure)
  for (const f of entries) {
    const full = path.join(dir, f)
    try {
      if (f.toLowerCase().endsWith('.mkv') && fs.statSync(full).isFile()) {
        files.push([full, f])
      }
    } catch { /* skip */ }
  }

  return files
}

// Collect all MKV files, handling release folder nesting
function collectMkvFiles(mediaRoot) {
  let files = collectFromDir(mediaRoot)

  if (files.length === 0) {
    // Look one level deeper for release folders
    let entries
    try { entries = fs.readdirSync(mediaRoot) } catch { return [] }
    for (const entry of entries) {
      if (entry.startsWith('.')) continue
      const subdir = path.join(mediaRoot, entry)
      try {
        if (!fs.statSync(subdir).isDirectory()) continue
      } catch { continue }
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

// Extract episode title from filename
function extractTitle(filename, codeMatch) {
  const afterCode = filename.slice(codeMatch.index + codeMatch[0].length)

  // Hyphen-separated: " - Title (quality).mkv"
  if (/^\s*-\s*/.test(afterCode)) {
    let title = afterCode.replace(/^\s*-\s*/, '')
    title = title.replace(/\s*\([^)]*\)\s*\.mkv$/i, '')
    title = title.replace(/\.mkv$/i, '')
    return title.trim() || null
  }

  // Dot-separated: ".Title.Here.1080p..."
  if (/^\./.test(afterCode)) {
    let title = afterCode.replace(/^\./, '')
    title = title.replace(/\.(?:\d{3,4}p|WEB[-.]?DL|WEBRip|BluRay|BDRip|BDRemux|HDTV|DVDRip|AMZN|REPACK).*$/i, '')
    title = title.replace(/\./g, ' ').trim()
    if (/^\d{3,4}p$/i.test(title)) return null
    return title || null
  }

  return null
}

// Parse episode info from filename
function parseEpisode(filename) {
  const match = filename.match(EPISODE_CODE_RE)
  if (!match) return null

  const season = parseInt(match[1], 10)
  const episode = parseInt(match[2], 10)
  const code = `S${String(season).padStart(2, '0')}E${String(episode).padStart(2, '0')}`
  const title = extractTitle(filename, match)

  return { season, episode, title: title || code, code }
}

// Scan a series folder and upsert episodes
function scan(seriesId) {
  const s = db.series.findById(seriesId)
  if (!s) return 0

  if (!fs.existsSync(s.media_path)) {
    console.warn(`MediaScanner: media root not found: ${s.media_path}`)
    return 0
  }

  const mkvFiles = collectMkvFiles(s.media_path)
  let count = 0

  for (const [fullPath, filename] of mkvFiles) {
    const ep = parseEpisode(filename)
    if (!ep) continue

    db.episodes.upsert({
      series_id: seriesId,
      code: ep.code,
      title: ep.title,
      season_number: ep.season,
      episode_number: ep.episode,
      file_path: fullPath,
    })
    count++
  }

  console.log(`MediaScanner: scanned ${count} episodes for '${s.name}'`)
  return count
}

// Add a series from a folder path: create/find series, scan, fetch metadata
async function addFromPath(folderPath, fetchMetadata) {
  folderPath = folderPath.trim()
  const name = nameFromPath(folderPath)

  let s = db.series.findByMediaPath(folderPath)
  if (!s) {
    s = db.series.create({ name, media_path: folderPath })
  }

  scan(s.id)

  if (fetchMetadata) {
    await fetchMetadata(s)
  }

  return db.series.findById(s.id)
}

module.exports = { scan, addFromPath, nameFromPath, parseEpisode, collectMkvFiles }
