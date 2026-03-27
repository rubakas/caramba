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
  db = new Database(dbPath)
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

// -- Schema migration --

function migrate() {
  const schemaPath = path.join(__dirname, 'schema.sql')
  const schema = fs.readFileSync(schemaPath, 'utf-8')
  db.exec(schema)
}

// -- Helper: generate slug --

function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
}

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
    const stmt = get().prepare(
      'INSERT INTO series (name, slug, media_path) VALUES (?, ?, ?)'
    )
    const result = stmt.run(name, s, media_path)
    return this.findById(result.lastInsertRowid)
  },

  update(id, fields) {
    const keys = Object.keys(fields)
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
    const keys = Object.keys(fields)
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
    const keys = Object.keys(fields)
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

// -- Playback Preferences (per-series / per-movie) --

const playbackPreferences = {
  forSeries(seriesId) {
    return get().prepare('SELECT * FROM playback_preferences WHERE series_id = ?').get(seriesId)
  },

  forMovie(movieId) {
    return get().prepare('SELECT * FROM playback_preferences WHERE movie_id = ?').get(movieId)
  },

  saveSeries(seriesId, { audio_language, subtitle_language, subtitle_off }) {
    get().prepare(`
      INSERT INTO playback_preferences (series_id, audio_language, subtitle_language, subtitle_off)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(series_id) DO UPDATE SET
        audio_language = excluded.audio_language,
        subtitle_language = excluded.subtitle_language,
        subtitle_off = excluded.subtitle_off,
        updated_at = datetime('now')
    `).run(seriesId, audio_language || null, subtitle_language || null, subtitle_off ? 1 : 0)
  },

  saveMovie(movieId, { audio_language, subtitle_language, subtitle_off }) {
    get().prepare(`
      INSERT INTO playback_preferences (movie_id, audio_language, subtitle_language, subtitle_off)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(movie_id) DO UPDATE SET
        audio_language = excluded.audio_language,
        subtitle_language = excluded.subtitle_language,
        subtitle_off = excluded.subtitle_off,
        updated_at = datetime('now')
    `).run(movieId, audio_language || null, subtitle_language || null, subtitle_off ? 1 : 0)
  },
}

module.exports = { open, close, get, getDbPath, getStoragePath, slugify, series, episodes, movies, watchHistories, playbackPreferences }
