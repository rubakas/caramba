CREATE TABLE IF NOT EXISTS series (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  media_path TEXT NOT NULL,
  description TEXT,
  poster_url TEXT,
  tvmaze_id INTEGER,
  imdb_id TEXT,
  genres TEXT,
  rating REAL,
  premiered TEXT,
  status TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_series_slug ON series(slug);

CREATE TABLE IF NOT EXISTS episodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  title TEXT,
  season_number INTEGER,
  episode_number INTEGER,
  file_path TEXT,
  air_date TEXT,
  description TEXT,
  runtime INTEGER,
  tvmaze_id INTEGER,
  watched INTEGER NOT NULL DEFAULT 0,
  progress_seconds INTEGER NOT NULL DEFAULT 0,
  duration_seconds INTEGER NOT NULL DEFAULT 0,
  last_watched_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_episodes_series_code ON episodes(series_id, code);
CREATE INDEX IF NOT EXISTS idx_episodes_series ON episodes(series_id);

CREATE TABLE IF NOT EXISTS movies (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  file_path TEXT NOT NULL UNIQUE,
  year TEXT,
  description TEXT,
  poster_url TEXT,
  imdb_id TEXT,
  genres TEXT,
  rating REAL,
  director TEXT,
  runtime INTEGER,
  watched INTEGER DEFAULT 0,
  progress_seconds INTEGER NOT NULL DEFAULT 0,
  duration_seconds INTEGER NOT NULL DEFAULT 0,
  last_watched_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_movies_slug ON movies(slug);
CREATE UNIQUE INDEX IF NOT EXISTS idx_movies_file ON movies(file_path);

CREATE TABLE IF NOT EXISTS watch_histories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
  started_at TEXT,
  ended_at TEXT,
  progress_seconds INTEGER,
  duration_seconds INTEGER,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_wh_episode ON watch_histories(episode_id);
