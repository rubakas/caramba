// Filename / path parser. Single source of truth for naming rules.
// Mirror of server/app/services/filename_parser_service.rb (which is the
// authoritative spec). Same regex registry, same defensive guards.
//
// Public API:
//   parse(filepath)           -> result object
//   extractProviderIds(text)  -> { imdb, tmdb, tvdb, tvmaze }
//   seasonFromFolder(name)    -> number | null
//   extraKind(filepath)       -> string | null
//   videoFile(filename)       -> boolean
//   nameFromFilename(path)    -> string  (back-compat helper)
//   yearFromFilename(path)    -> string | null

const path = require('path')

const VIDEO_EXTENSIONS = ['.mkv', '.mp4', '.avi', '.mov', '.m4v', '.ts', '.m2ts', '.webm', '.wmv', '.mpg', '.mpeg', '.flv']

const KNOWN_STRIP_EXTENSIONS = new Set(VIDEO_EXTENSIONS.concat([
  '.nfo', '.srt', '.ass', '.ssa', '.vtt', '.sub', '.idx', '.jpg', '.jpeg', '.png', '.webp',
]))

// Episode patterns — first match wins. Each may have named capture groups
// `season`, `ep`, `episode_end`. JS regex named groups use (?<name>...).
const EPISODE_PATTERNS = [
  /[Ss](?<season>\d{1,2})[ ._\-]*[Ee](?<ep>\d{1,3})(?:[ ._\-]?[Ee](?<episode_end>\d{1,3}))?/i,
  /(?<![\d])(?<season>\d{1,2})x(?<ep>\d{1,3})(?:[\-x](?<episode_end>\d{1,3}))?/i,
  /[Ss]eason\s*(?<season>\d{1,2})\s+[Ee]pisode\s*(?<ep>\d{1,3})/i,
  /\b[Ee]pisode\s+(?<ep>\d{1,3})\b/,
  /[._\s\-][Ee][Pp]?_?(?<ep>\d{1,3})(?:[._\s\-]|$)/,
  // Anime fan-sub bracketed: "[Group] Series - 04 [BDRip]"
  /\[[^\]]+\][\s_]*(?<seriesname>[^\[\]]+?)[\s_]+-[\s_]+(?<ep>\d{1,3})(?:v\d+)?[\s_]*(?:\[|$)/,
]

const DATE_PATTERNS = [
  /(?<year>\d{4})[._\-](?<month>\d{2})[._\-](?<day>\d{2})/,
  /(?<day>\d{2})[._\-](?<month>\d{2})[._\-](?<year>\d{4})/,
]

// Year extraction with disambiguation lookahead.
const YEAR_PATTERN = /[\s._\-(\[](?<year>(?:19|20)\d{2})(?![0-9]|\W\d{2}\W\d{2})(?:[\s._\-)\]]|$)/

const PROVIDER_ID_BRACKET = /[\[(\{](?<key>imdb|tmdb|tvdb|tvmaze)id[\-=](?<value>[A-Za-z0-9]+)[\])\}]/gi
const IMDB_LOOSE = /\btt(\d{7,8})\b/

const SEASON_FOLDER_PATTERNS = [
  /^\s*(?:season|saison|staffel|stagione|temporada|сезон|сезон\s*№?)\s*(?<season>\d{1,3})\s*$/i,
  /^\s*(?<season>\d{1,3})(?:st|nd|rd|th|\.)\s*(?:season|saison|staffel)\s*$/i,
  /^\s*[sS](?<season>\d{1,3})\s*$/,
]

const SPECIAL_FOLDER_PATTERN = /^(?:specials?|extras?)$/i

// CleanString chain — chained noise removal.
const CLEAN_STRING_PATTERNS = [
  // Codec / source / language alternation.
  /^\s*(?<cleaned>.+?)[\s_,.()\[\]\-](?:3d|sbs|tab|hsbs|htab|mvc|hdr|hdr10|dolby[._\-\s]?vision|dv|uhd|ultrahd|4k|8k|2160p|1080p|1080i|720p|720i|576p|576i|480p|480i|360p|240p|ac3|dts(?:-?hd)?|truehd|atmos|aac2?|e?ac3|ddp?5\.1|flac|opus|vorbis|mp3|h\.?264|h\.?265|hevc|avc|x264|x265|xvid|divx|av1|vp9|bluray|blu-?ray|bdrip|brrip|bdremux|web[\-.]?dl|webrip|hdtv|hdrip|hdtvrip|dvdrip|dvdscr|dvdscreener|screener|cam|telesync|ts|telecine|tc|hddvd|amzn|nf|hulu|atv|dsnp|max|hbo|hmax|repack|proper|rerip|extended|unrated|directors?\.?cut|theatrical|imax|criterion|remastered|remux|multi|dual|hindi|english|rus|russian|italian|german|french|spanish|korean|japanese|chinese|polish|portuguese|dutch|ukr|ukrainian)(?:[\s_,.()\[\]\-]|$)/i,
  /^\s*(?<cleaned>.+?)(?:\s*\[[^\]]+\]\s*)+$/,
  /^\s*\[[^\]]+\]\s*(?<cleaned>.+)$/,
  /^\s*(?<cleaned>.+?)\W[Ee]\d+(?:-|~)[Ee]?\d+(?:\W|$)/,
  /^\s*(?<cleaned>.+?)\s+-\s+\d{1,4}\s*$/,
  /^\s*(?<cleaned>.+?)(?:[._\-\s](?:trailer|sample|scene|clip|behindthescenes|deleted|deletedscene|featurette|short|interview|other|extra))$/i,
  /^\s*(?<cleaned>.+?)[._\s\-](?:[Ss]eason[._\s\-]?\d{1,3}|[Ss]\d{1,3})\s*$/,
]

const EXTRA_DIRECTORIES = {
  trailers: 'trailer',
  samples: 'sample',
  extras: 'extra',
  scenes: 'scene',
  shorts: 'short',
  featurettes: 'featurette',
  interviews: 'interview',
  'behind the scenes': 'behindthescenes',
  behindthescenes: 'behindthescenes',
  'deleted scenes': 'deletedscene',
  deletedscenes: 'deletedscene',
  clips: 'clip',
}

const EXTRA_FILENAME_EXACT = {
  trailer: 'trailer',
  sample: 'sample',
  theme: 'themesong',
}

const EXTRA_SUFFIX_PATTERN = /[._\-\s](?<kind>trailer|sample|scene|clip|behindthescenes|deleted|deletedscene|featurette|short|interview|extra|other|theme)$/i

function stripKnownExtension(name) {
  const ext = path.extname(name).toLowerCase()
  if (!KNOWN_STRIP_EXTENSIONS.has(ext)) return name
  return path.basename(name, path.extname(name))
}

function videoFile(filename) {
  return VIDEO_EXTENSIONS.includes(path.extname(filename).toLowerCase())
}

function extractProviderIds(text) {
  const ids = {}
  if (!text) return ids
  for (const m of text.matchAll(PROVIDER_ID_BRACKET)) {
    const { key, value } = m.groups || {}
    if (key) ids[key.toLowerCase()] = value
  }
  if (!ids.imdb) {
    const m = text.match(IMDB_LOOSE)
    if (m) ids.imdb = `tt${m[1]}`
  }
  return ids
}

function seasonFromFolder(name) {
  if (!name) return null
  const trimmed = name.trim()
  if (SPECIAL_FOLDER_PATTERN.test(trimmed)) return 0
  for (const re of SEASON_FOLDER_PATTERNS) {
    const m = trimmed.match(re)
    if (m && m.groups && m.groups.season) return parseInt(m.groups.season, 10)
  }
  return null
}

function extraKind(filepath) {
  if (!filepath) return null
  const basename = path.basename(filepath, path.extname(filepath)).toLowerCase()
  const dirname = path.basename(path.dirname(filepath)).toLowerCase()

  if (EXTRA_DIRECTORIES[dirname]) return EXTRA_DIRECTORIES[dirname]
  if (EXTRA_FILENAME_EXACT[basename]) return EXTRA_FILENAME_EXACT[basename]
  const m = basename.match(EXTRA_SUFFIX_PATTERN)
  if (m && m.groups && m.groups.kind) return m.groups.kind.toLowerCase()
  return null
}

function matchEpisode(text) {
  for (const re of EPISODE_PATTERNS) {
    const m = text.match(re)
    if (m) return m
  }
  return null
}

function matchDate(text) {
  for (const re of DATE_PATTERNS) {
    const m = text.match(re)
    if (m && m.groups) {
      const y = parseInt(m.groups.year, 10)
      const mo = parseInt(m.groups.month, 10)
      const d = parseInt(m.groups.day, 10)
      if (y >= 1900 && y <= 2100 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) return m
    }
  }
  return null
}

function cleanTitle(basename, epMatch, dateMatch, yearMatch) {
  const candidates = [
    epMatch && epMatch.index,
    dateMatch && dateMatch.index,
    yearMatch && yearMatch.index,
  ].filter((v) => typeof v === 'number')
  const cutoff = candidates.length ? Math.min(...candidates) : null

  let candidate = cutoff != null ? basename.slice(0, cutoff) : basename
  let cleaned = candidate
  let prev = null
  while (cleaned !== prev) {
    prev = cleaned
    for (const re of CLEAN_STRING_PATTERNS) {
      const m = cleaned.match(re)
      if (m && m.groups && m.groups.cleaned && m.groups.cleaned.trim()) {
        cleaned = m.groups.cleaned
      }
    }
  }
  cleaned = cleaned.replace(/[._]/g, ' ').replace(/\s+/g, ' ').trim()
  cleaned = cleaned.replace(/[\s\-\[(\{]+$/, '').trim()
  if (cleaned) return cleaned
  const fallback = candidate.replace(/[._]/g, ' ').trim()
  return fallback || basename
}

const SEASON_NUMBER_INVALID = (n) => n >= 200 && (n < 1928 || n > 2500)

function parse(filepath) {
  const basename = stripKnownExtension(path.basename(filepath || ''))
  const normalized = basename.replace(/_/g, '-')

  const providerIds = extractProviderIds(filepath || '')
  const isExtra = extraKind(filepath || '')

  const epMatch = matchEpisode(normalized)
  const dateMatch = epMatch ? null : matchDate(normalized)
  const yearMatch = basename.match(YEAR_PATTERN)
  const year = yearMatch && yearMatch.groups ? parseInt(yearMatch.groups.year, 10) : null

  const title = cleanTitle(basename, epMatch, dateMatch, yearMatch)

  const result = {
    type: 'movie',
    title,
    year,
    season: null,
    episode: null,
    episode_end: null,
    air_date: null,
    provider_ids: providerIds,
    is_extra: isExtra,
    raw: basename,
  }

  if (epMatch) {
    const groups = epMatch.groups || {}
    const season = groups.season ? parseInt(groups.season, 10) : null
    if (season != null && SEASON_NUMBER_INVALID(season)) return result

    result.type = 'episode'
    result.season = season != null ? season : 1
    result.episode = groups.ep ? parseInt(groups.ep, 10) : null
    result.episode_end = groups.episode_end ? parseInt(groups.episode_end, 10) : null
  } else if (dateMatch) {
    const g = dateMatch.groups
    result.type = 'episode'
    result.air_date = `${g.year.padStart(4, '0')}-${g.month.padStart(2, '0')}-${g.day.padStart(2, '0')}`
  }
  return result
}

function nameFromFilename(filepath) {
  return parse(filepath).title
}

function yearFromFilename(filepath) {
  const y = parse(filepath).year
  return y != null ? String(y) : null
}

module.exports = {
  parse,
  extractProviderIds,
  seasonFromFolder,
  extraKind,
  videoFile,
  nameFromFilename,
  yearFromFilename,
  VIDEO_EXTENSIONS,
}
