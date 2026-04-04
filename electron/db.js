const Database = require('better-sqlite3')
const path = require('path')
const fs = require('fs')
const { app } = require('electron')

let db = null

function getStoragePath() {
  // In packaged app, use userData; in dev, use ./storage
  if (app.isPackaged) {
    const p = path.join(app.getPath('userData'), 'storage')
    fs.mkdirSync(p, { recursive: true })
    return p
  }
  const p = path.join(__dirname, '..', 'storage')
  fs.mkdirSync(p, { recursive: true })
  return p
}

function getDbPath() {
  return path.join(getStoragePath(), 'development.sqlite3')
}

function open() {
  if (db) return db
  const dbPath = getDbPath()
  try {
    db = new Database(dbPath)
  } catch (err) {
    // Handle locked or corrupted database on open
    console.error('[DB] Failed to open database:', err.message)
    if (err.code === 'SQLITE_BUSY' || err.message.includes('database is locked')) {
      throw new Error('Database is locked by another process. Close other instances and retry.')
    }
    if (err.code === 'SQLITE_CORRUPT' || err.message.includes('not a database')) {
      throw new Error('Database file is corrupted. Please restore from backup.')
    }
    throw err
  }
  db.pragma('journal_mode = WAL')
  db.pragma('foreign_keys = ON')
  migrate()
  return db
}

function close() {
  if (db) {
    db.close()
    db = null
  }
}

function get() {
  if (!db) open()
  return db
}

/**
 * Wrap a database write operation with error handling for disk-full / locked DB.
 * Returns the result of fn(), or throws with a user-friendly message.
 */
function safeWrite(fn) {
  try {
    return fn()
  } catch (err) {
    if (err.code === 'SQLITE_FULL' || err.message?.includes('database or disk is full')) {
      console.error('[DB] Disk full — write failed:', err.message)
      throw new Error('Disk is full. Free up space and try again.')
    }
    if (err.code === 'SQLITE_BUSY' || err.message?.includes('database is locked')) {
      console.error('[DB] Database locked — write failed:', err.message)
      throw new Error('Database is busy. Try again in a moment.')
    }
    throw err
  }
}

// -- Schema migration --

function migrate() {
  const schemaPath = path.join(__dirname, 'schema.sql')
  const schema = fs.readFileSync(schemaPath, 'utf-8')
  db.exec(schema)
  migrateWatchlist()
  migratePlaybackPreferences()
}

function migrateWatchlist() {
  // Check if watchlist table needs migration (old schema had tvmaze_id NOT NULL UNIQUE)
  const cols = db.prepare("PRAGMA table_info(watchlist)").all()
  const colNames = cols.map(c => c.name)

  // Check if tvmaze_id still has NOT NULL constraint (old schema)
  const tvmazeCol = cols.find(c => c.name === 'tvmaze_id')
  const needsRecreate = tvmazeCol && tvmazeCol.notnull === 1

  if (needsRecreate) {
    // Recreate watchlist table: migrate data, drop old, create new
    // Wrapped in a transaction so a crash mid-migration cannot orphan data
    const migrateWatchlistTx = db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS watchlist_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL DEFAULT 'show',
          tvmaze_id INTEGER,
          name TEXT NOT NULL,
          poster_url TEXT,
          description TEXT,
          genres TEXT,
          rating REAL,
          premiered TEXT,
          status TEXT,
          network TEXT,
          imdb_id TEXT,
          year TEXT,
          director TEXT,
          runtime INTEGER,
          created_at TEXT NOT NULL DEFAULT (datetime('now')),
          updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )
      `)
      // Copy existing show entries
      db.exec(`
        INSERT INTO watchlist_new (type, tvmaze_id, name, poster_url, description, genres, rating, premiered, status, network, imdb_id, created_at, updated_at)
        SELECT 'show', tvmaze_id, name, poster_url, description, genres, rating, premiered, status, network, imdb_id, created_at, updated_at
        FROM watchlist
      `)
      db.exec('DROP TABLE watchlist')
      db.exec('ALTER TABLE watchlist_new RENAME TO watchlist')
    })
    migrateWatchlistTx()
  } else {
    // Just add missing columns
    if (!colNames.includes('type')) {
      db.exec("ALTER TABLE watchlist ADD COLUMN type TEXT NOT NULL DEFAULT 'show'")
    }
    if (!colNames.includes('year')) {
      db.exec("ALTER TABLE watchlist ADD COLUMN year TEXT")
    }
    if (!colNames.includes('director')) {
      db.exec("ALTER TABLE watchlist ADD COLUMN director TEXT")
    }
    if (!colNames.includes('runtime')) {
      db.exec("ALTER TABLE watchlist ADD COLUMN runtime INTEGER")
    }
  }

  // Create partial unique indexes (safe — IF NOT EXISTS)
  db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_watchlist_tvmaze ON watchlist(tvmaze_id) WHERE tvmaze_id IS NOT NULL")
  db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_watchlist_imdb ON watchlist(imdb_id) WHERE imdb_id IS NOT NULL")
}

function migratePlaybackPreferences() {
  const cols = db.prepare("PRAGMA table_info(playback_preferences)").all()
  const colNames = cols.map(c => c.name)
  if (!colNames.includes('subtitle_size')) {
    db.exec("ALTER TABLE playback_preferences ADD COLUMN subtitle_size TEXT NOT NULL DEFAULT 'medium'")
  }
  if (!colNames.includes('subtitle_style')) {
    db.exec("ALTER TABLE playback_preferences ADD COLUMN subtitle_style TEXT NOT NULL DEFAULT 'classic'")
  }
}

// -- Helper: generate slug --

function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

// -- Security: validate a file path belongs to a registered media directory --

/**
 * Check if a file path is within any registered series media_path or matches
 * a known movie file_path. Returns true if the path is safe to operate on.
 */
function isKnownMediaPath(filePath) {
  if (!filePath || !db) return false
  const normalized = path.resolve(filePath)

  // Check against all series media directories
  const allSeries = get().prepare('SELECT media_path FROM series').all()
  for (const s of allSeries) {
    if (s.media_path && normalized.startsWith(path.resolve(s.media_path) + path.sep)) return true
    if (s.media_path && normalized === path.resolve(s.media_path)) return true
  }

  // Check if it's a known movie file
  const movie = get().prepare('SELECT id FROM movies WHERE file_path = ?').get(normalized)
  if (movie) return true

  // Check if it's a known episode file
  const episode = get().prepare('SELECT id FROM episodes WHERE file_path = ?').get(normalized)
  if (episode) return true

  return false
}

// -- Allowed column names for dynamic update functions (prevents SQL injection) --

const SERIES_UPDATE_COLS = new Set([
  'name', 'slug', 'media_path', 'poster_url', 'banner_url', 'description',
  'genres', 'rating', 'premiered', 'status', 'network', 'tvmaze_id', 'imdb_id',
])

const MOVIES_UPDATE_COLS = new Set([
  'title', 'slug', 'file_path', 'year', 'poster_url', 'banner_url', 'description',
  'genres', 'rating', 'director', 'runtime', 'imdb_id', 'tmdb_id',
  'watched', 'progress_seconds', 'duration_seconds',
])

const EPISODES_UPDATE_COLS = new Set([
  'title', 'code', 'season_number', 'episode_number', 'file_path',
  'description', 'runtime', 'rating', 'aired',
  'watched', 'progress_seconds', 'duration_seconds',
])

// -- Series CRUD --

const series = {
  all() {
    return get().prepare(`
      SELECT s.*,
        (SELECT COUNT(*) FROM episodes WHERE series_id = s.id) AS total_episodes,
        (SELECT COUNT(*) FROM episodes WHERE series_id = s.id AND watched = 1) AS watched_episodes
      FROM series s ORDER BY s.name
    `).all()
  },

  findBySlug(slug) {
    return get().prepare('SELECT * FROM series WHERE slug = ?').get(slug)
  },

  findById(id) {
    return get().prepare('SELECT * FROM series WHERE id = ?').get(id)
  },

  findByMediaPath(mediaPath) {
    return get().prepare('SELECT * FROM series WHERE media_path = ?').get(mediaPath)
  },

  create({ name, slug, media_path }) {
    const s = slug || slugify(name)
    // Handle slug collision (same pattern as movies.create)
    let finalSlug = s
    let counter = 1
    while (get().prepare('SELECT id FROM series WHERE slug = ?').get(finalSlug)) {
      finalSlug = `${s}-${counter++}`
    }
    const stmt = get().prepare(
      'INSERT INTO series (name, slug, media_path) VALUES (?, ?, ?)'
    )
    const result = stmt.run(name, finalSlug, media_path)
    return this.findById(result.lastInsertRowid)
  },

  update(id, fields) {
    const keys = Object.keys(fields).filter(k => SERIES_UPDATE_COLS.has(k))
    if (keys.length === 0) return
    const sets = keys.map(k => `${k} = ?`).join(', ')
    const vals = keys.map(k => fields[k])
    get().prepare(`UPDATE series SET ${sets}, updated_at = datetime('now') WHERE id = ?`).run(...vals, id)
  },

  destroy(id) {
    get().prepare('DELETE FROM series WHERE id = ?').run(id)
  },

  seasonCount(id) {
    const row = get().prepare(
      'SELECT COUNT(DISTINCT season_number) AS c FROM episodes WHERE series_id = ?'
    ).get(id)
    return row ? row.c : 0
  },

  totalWatchTime(id) {
    const row = get().prepare(
      'SELECT SUM(wh.progress_seconds) AS total FROM watch_histories wh JOIN episodes e ON wh.episode_id = e.id WHERE e.series_id = ?'
    ).get(id)
    return row ? row.total || 0 : 0
  },
}

// -- Episodes CRUD --

const episodes = {
  forSeries(seriesId) {
    return get().prepare(
      'SELECT * FROM episodes WHERE series_id = ? ORDER BY season_number, episode_number'
    ).all(seriesId)
  },

  countForSeries(seriesId) {
    const row = get().prepare('SELECT COUNT(*) AS c FROM episodes WHERE series_id = ?').get(seriesId)
    return row ? row.c : 0
  },

  countWatchedForSeries(seriesId) {
    const row = get().prepare('SELECT COUNT(*) AS c FROM episodes WHERE series_id = ? AND watched = 1').get(seriesId)
    return row ? row.c : 0
  },

  forSeason(seriesId, seasonNum) {
    return get().prepare(
      'SELECT * FROM episodes WHERE series_id = ? AND season_number = ? ORDER BY episode_number'
    ).all(seriesId, seasonNum)
  },

  seasons(seriesId) {
    return get().prepare(
      'SELECT DISTINCT season_number FROM episodes WHERE series_id = ? ORDER BY season_number'
    ).all(seriesId).map(r => r.season_number)
  },

  findById(id) {
    return get().prepare('SELECT * FROM episodes WHERE id = ?').get(id)
  },

  findByCode(seriesId, code) {
    return get().prepare(
      'SELECT * FROM episodes WHERE series_id = ? AND code = ?'
    ).get(seriesId, code)
  },

  upsert({ series_id, code, title, season_number, episode_number, file_path }) {
    const existing = this.findByCode(series_id, code)
    if (existing) {
      get().prepare(`
        UPDATE episodes SET title = ?, season_number = ?, episode_number = ?, file_path = ?, updated_at = datetime('now')
        WHERE id = ?
      `).run(title, season_number, episode_number, file_path, existing.id)
      return this.findById(existing.id)
    }
    const result = get().prepare(`
      INSERT INTO episodes (series_id, code, title, season_number, episode_number, file_path)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(series_id, code, title, season_number, episode_number, file_path)
    return this.findById(result.lastInsertRowid)
  },

  updateMetadata(id, fields) {
    const keys = Object.keys(fields).filter(k => EPISODES_UPDATE_COLS.has(k))
    if (keys.length === 0) return
    const sets = keys.map(k => `${k} = ?`).join(', ')
    const vals = keys.map(k => fields[k])
    get().prepare(`UPDATE episodes SET ${sets}, updated_at = datetime('now') WHERE id = ?`).run(...vals, id)
  },

  markWatched(id) {
    get().prepare(`
      UPDATE episodes SET watched = 1, last_watched_at = datetime('now'), updated_at = datetime('now') WHERE id = ?
    `).run(id)
  },

  markUnwatched(id) {
    get().prepare(`
      UPDATE episodes SET watched = 0, progress_seconds = 0, last_watched_at = NULL, updated_at = datetime('now') WHERE id = ?
    `).run(id)
  },

  markPriorWatched(seriesId, seasonNumber, episodeNumber) {
    get().prepare(`
      UPDATE episodes SET watched = 1, last_watched_at = datetime('now'), updated_at = datetime('now')
      WHERE series_id = ? AND (season_number < ? OR (season_number = ? AND episode_number < ?)) AND watched = 0
    `).run(seriesId, seasonNumber, seasonNumber, episodeNumber)
  },

  updateProgress(id, progressSeconds, durationSeconds) {
    get().prepare(`
      UPDATE episodes SET progress_seconds = ?, duration_seconds = ?, last_watched_at = datetime('now'), updated_at = datetime('now')
      WHERE id = ?
    `).run(progressSeconds, durationSeconds, id)
  },

  resumable(seriesId) {
    return get().prepare(`
      SELECT * FROM episodes WHERE series_id = ? AND progress_seconds > 0 AND duration_seconds > 0
      AND CAST(progress_seconds AS REAL) / duration_seconds < 0.9
      ORDER BY last_watched_at DESC LIMIT 1
    `).get(seriesId)
  },

  // Get the immediate next episode after the given episodeId (by season/episode order)
  // regardless of watched status — used for auto-play next
  getNext(episodeId) {
    const current = this.findById(episodeId)
    if (!current) return null
    return get().prepare(`
      SELECT * FROM episodes WHERE series_id = ?
      AND (season_number > ? OR (season_number = ? AND episode_number > ?))
      ORDER BY season_number, episode_number LIMIT 1
    `).get(current.series_id, current.season_number, current.season_number, current.episode_number) || null
  },

  nextUp(seriesId) {
    // Find last watched, then get the next unwatched episode
    const lastWatched = get().prepare(`
      SELECT * FROM episodes WHERE series_id = ? AND watched = 1 ORDER BY season_number DESC, episode_number DESC LIMIT 1
    `).get(seriesId)

    if (lastWatched) {
      const next = get().prepare(`
        SELECT * FROM episodes WHERE series_id = ? AND watched = 0
        AND (season_number > ? OR (season_number = ? AND episode_number > ?))
        ORDER BY season_number, episode_number LIMIT 1
      `).get(seriesId, lastWatched.season_number, lastWatched.season_number, lastWatched.episode_number)
      if (next) return next
    }
    // Fallback: first unwatched
    return get().prepare(
      'SELECT * FROM episodes WHERE series_id = ? AND watched = 0 ORDER BY season_number, episode_number LIMIT 1'
    ).get(seriesId)
  },
}

// -- Movies CRUD --

const movies = {
  all() {
    return get().prepare('SELECT * FROM movies ORDER BY title').all()
  },

  findBySlug(slug) {
    return get().prepare('SELECT * FROM movies WHERE slug = ?').get(slug)
  },

  findById(id) {
    return get().prepare('SELECT * FROM movies WHERE id = ?').get(id)
  },

  findByFilePath(filePath) {
    return get().prepare('SELECT * FROM movies WHERE file_path = ?').get(filePath)
  },

  create({ title, slug, file_path, year }) {
    const s = slug || slugify(title + (year ? `-${year}` : ''))
    // Handle slug collision
    let finalSlug = s
    let counter = 1
    while (get().prepare('SELECT id FROM movies WHERE slug = ?').get(finalSlug)) {
      finalSlug = `${s}-${counter++}`
    }
    const result = get().prepare(
      'INSERT OR IGNORE INTO movies (title, slug, file_path, year) VALUES (?, ?, ?, ?)'
    ).run(title, finalSlug, file_path, year || null)
    if (result.changes === 0) return this.findByFilePath(file_path)
    return this.findById(result.lastInsertRowid)
  },

  update(id, fields) {
    const keys = Object.keys(fields).filter(k => MOVIES_UPDATE_COLS.has(k))
    if (keys.length === 0) return
    const sets = keys.map(k => `${k} = ?`).join(', ')
    const vals = keys.map(k => fields[k])
    get().prepare(`UPDATE movies SET ${sets}, updated_at = datetime('now') WHERE id = ?`).run(...vals, id)
  },

  destroy(id) {
    get().prepare('DELETE FROM movies WHERE id = ?').run(id)
  },

  markWatched(id) {
    get().prepare(`
      UPDATE movies SET watched = 1, last_watched_at = datetime('now'), updated_at = datetime('now') WHERE id = ?
    `).run(id)
  },

  markUnwatched(id) {
    get().prepare(`
      UPDATE movies SET watched = 0, progress_seconds = 0, last_watched_at = NULL, updated_at = datetime('now') WHERE id = ?
    `).run(id)
  },

  updateProgress(id, progressSeconds, durationSeconds) {
    get().prepare(`
      UPDATE movies SET progress_seconds = ?, duration_seconds = ?, last_watched_at = datetime('now'), updated_at = datetime('now')
      WHERE id = ?
    `).run(progressSeconds, durationSeconds, id)
  },
}

// -- Watch History --

const watchHistories = {
  create({ episode_id, started_at }) {
    const result = get().prepare(
      'INSERT INTO watch_histories (episode_id, started_at) VALUES (?, ?)'
    ).run(episode_id, started_at || new Date().toISOString())
    return this.findById(result.lastInsertRowid)
  },

  findById(id) {
    return get().prepare('SELECT * FROM watch_histories WHERE id = ?').get(id)
  },

  updateProgress(id, progressSeconds, durationSeconds) {
    get().prepare(`
      UPDATE watch_histories SET progress_seconds = ?, duration_seconds = ?, ended_at = datetime('now'), updated_at = datetime('now')
      WHERE id = ?
    `).run(progressSeconds, durationSeconds, id)
  },

  recent(limit = 100) {
    return get().prepare(`
      SELECT wh.*, e.code, e.title AS episode_title, e.season_number, e.episode_number,
             s.name AS series_name, s.slug AS series_slug, s.poster_url AS series_poster
      FROM watch_histories wh
      JOIN episodes e ON wh.episode_id = e.id
      JOIN series s ON e.series_id = s.id
      ORDER BY wh.started_at DESC
      LIMIT ?
    `).all(limit)
  },

  stats() {
    const totalTime = get().prepare('SELECT SUM(progress_seconds) AS t FROM watch_histories').get()
    const totalEpisodes = get().prepare('SELECT COUNT(DISTINCT episode_id) AS c FROM watch_histories').get()
    const totalSeries = get().prepare(`
      SELECT COUNT(DISTINCT s.id) AS c FROM watch_histories wh
      JOIN episodes e ON wh.episode_id = e.id JOIN series s ON e.series_id = s.id
    `).get()
    return {
      total_time: totalTime?.t || 0,
      total_episodes: totalEpisodes?.c || 0,
      total_series: totalSeries?.c || 0,
    }
  },
}

// -- Watchlist (Discover) --

const watchlist = {
  all() {
    return get().prepare('SELECT * FROM watchlist ORDER BY created_at DESC').all()
  },

  findByTvmazeId(tvmazeId) {
    return get().prepare('SELECT * FROM watchlist WHERE tvmaze_id = ?').get(tvmazeId)
  },

  findByImdbId(imdbId) {
    return get().prepare('SELECT * FROM watchlist WHERE imdb_id = ?').get(imdbId)
  },

  addShow({ tvmaze_id, name, poster_url, description, genres, rating, premiered, status, network, imdb_id }) {
    get().prepare(`
      INSERT OR IGNORE INTO watchlist (type, tvmaze_id, name, poster_url, description, genres, rating, premiered, status, network, imdb_id)
      VALUES ('show', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(tvmaze_id, name, poster_url || null, description || null, genres || null, rating || null, premiered || null, status || null, network || null, imdb_id || null)
    return this.findByTvmazeId(tvmaze_id)
  },

  addMovie({ imdb_id, name, poster_url, description, genres, rating, year, director, runtime }) {
    get().prepare(`
      INSERT OR IGNORE INTO watchlist (type, imdb_id, name, poster_url, description, genres, rating, year, director, runtime)
      VALUES ('movie', ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(imdb_id, name, poster_url || null, description || null, genres || null, rating || null, year || null, director || null, runtime || null)
    return this.findByImdbId(imdb_id)
  },

  // Legacy: keep old add() for backward compat (delegates to addShow)
  add(data) {
    if (data._type === 'movie' || data.type === 'movie') return this.addMovie(data)
    return this.addShow(data)
  },

  removeByTvmazeId(tvmazeId) {
    get().prepare('DELETE FROM watchlist WHERE tvmaze_id = ?').run(tvmazeId)
  },

  removeByImdbId(imdbId) {
    get().prepare('DELETE FROM watchlist WHERE imdb_id = ?').run(imdbId)
  },

  remove(identifier) {
    // Backward compat: if it's a number, treat as tvmaze_id
    if (typeof identifier === 'number') {
      this.removeByTvmazeId(identifier)
    } else if (typeof identifier === 'string') {
      this.removeByImdbId(identifier)
    }
  },
}

// -- Playback Preferences (per-series / per-movie) --

const playbackPreferences = {
  forSeries(seriesId) {
    return get().prepare('SELECT * FROM playback_preferences WHERE series_id = ?').get(seriesId)
  },

  forMovie(movieId) {
    return get().prepare('SELECT * FROM playback_preferences WHERE movie_id = ?').get(movieId)
  },

  saveSeries(seriesId, { audio_language, subtitle_language, subtitle_off, subtitle_size, subtitle_style }) {
    get().prepare(`
      INSERT INTO playback_preferences (series_id, audio_language, subtitle_language, subtitle_off, subtitle_size, subtitle_style)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(series_id) DO UPDATE SET
        audio_language = excluded.audio_language,
        subtitle_language = excluded.subtitle_language,
        subtitle_off = excluded.subtitle_off,
        subtitle_size = excluded.subtitle_size,
        subtitle_style = excluded.subtitle_style,
        updated_at = datetime('now')
    `).run(seriesId, audio_language || null, subtitle_language || null, subtitle_off ? 1 : 0, subtitle_size || 'medium', subtitle_style || 'classic')
  },

  saveMovie(movieId, { audio_language, subtitle_language, subtitle_off, subtitle_size, subtitle_style }) {
    get().prepare(`
      INSERT INTO playback_preferences (movie_id, audio_language, subtitle_language, subtitle_off, subtitle_size, subtitle_style)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(movie_id) DO UPDATE SET
        audio_language = excluded.audio_language,
        subtitle_language = excluded.subtitle_language,
        subtitle_off = excluded.subtitle_off,
        subtitle_size = excluded.subtitle_size,
        subtitle_style = excluded.subtitle_style,
        updated_at = datetime('now')
    `).run(movieId, audio_language || null, subtitle_language || null, subtitle_off ? 1 : 0, subtitle_size || 'medium', subtitle_style || 'classic')
  },
}

module.exports = { open, close, get, getDbPath, getStoragePath, slugify, isKnownMediaPath, safeWrite, series, episodes, movies, watchHistories, watchlist, playbackPreferences }
