# Caramba

Apple TV+ inspired episode tracker and media player built with Electron, React and SQLite.

Track TV series and movies, manage watch progress across devices with DB sync, and play media files directly in the app using ffmpeg hardware-accelerated transcoding.

## Features

- **Series Tracker** — scan a folder of TV episodes (SxxExx naming), auto-fetch metadata from TVMaze, track watched/unwatched state per episode, resume from where you left off, auto-play next episode
- **Movies** — add movie files, fetch metadata + posters from IMDb, track progress
- **In-App Video Player** — plays HEVC/H.265 MKV files via ffmpeg transcoding (HEVC→H.264 with VideoToolbox hardware acceleration), with subtitle support (VTT extraction + shifting), audio/subtitle track selection, and playback preferences saved per series/movie
- **VLC Integration** — open any file in VLC with HTTP-based progress tracking (polls VLC's HTTP API)
- **DB Sync** — sync your SQLite database to a shared folder (iCloud, Dropbox, etc.) so progress carries across machines. Uses `sqlite3 .backup` for safe copies, periodic sync every 30s
- **NowPlaying Bar** — persistent bottom bar showing current playback state for both in-app and VLC playback

## Tech Stack

| Layer    | Technology                                    |
| -------- | --------------------------------------------- |
| Frontend | React 19, React Router 7 (HashRouter), Vite 6 |
| Backend  | Electron 33, better-sqlite3                   |
| Player   | ffmpeg (VideoToolbox HW accel), HTML5 `<video>` |
| Metadata | TVMaze (series), imdbapi.dev (movies)          |
| Package  | electron-builder (DMG, AppImage, deb)          |

## Prerequisites

- **Node.js** >= 18
- **VLC** (optional) — for "Open in VLC" feature

## Getting Started

```bash
# Install dependencies
npm install

# Rebuild native modules for Electron
npx electron-rebuild

# Download static ffmpeg + ffprobe (bundled into the app)
bin/setup-ffmpeg

# Launch in dev mode
bin/dev

# Launch with simulated update banner (for testing the update UI)
SIMULATE_UPDATE=1 npm run electron
```

`bin/dev` builds the React frontend with Vite, then starts Electron. `SIMULATE_UPDATE=1` triggers a fake update notification on launch without hitting GitHub.

## Building

```bash
bin/build              # Mac + Linux
bin/build --mac        # Mac only
bin/build --linux      # Linux only
bin/build --publish    # Mac + Linux + publish to GitHub Releases
bin/build --mac --publish  # Mac + publish
```

The build script auto-increments the patch version in `package.json` on each new commit. If HEAD matches the last built commit (stored in `.build-commit`), the version stays the same for idempotent rebuilds.

Output goes to `dist/` — look for `.dmg`, `.AppImage`, or `.deb` files.

### Publishing

Pass `--publish` to upload built artifacts to GitHub Releases via the `gh` CLI:

- Creates a new release tagged `vMAJOR.MINOR.PATCH` with the latest commit message as notes
- If the release already exists (idempotent rebuild), overwrites the assets
- Requires `gh` to be installed and authenticated (`gh auth login`)

## Project Structure

```
electron/              Electron main process
  main.js              App entry, window, protocol handlers (stream://, subtitle://)
  preload.js           contextBridge API exposed to renderer
  db.js                SQLite CRUD helpers
  schema.sql           Database schema (single source of truth)
  ipc/                 IPC handler modules
    series.js          Series CRUD + scan + metadata
    episodes.js        Play, toggle watched, get next episode
    movies.js          Movie CRUD + play
    playback.js        Transcoder control, progress, VLC integration
    history.js         Watch history
    settings.js        DB sync config
    dialogs.js         Native file/folder dialogs
  services/
    transcoder.js      ffmpeg HEVC→H.264 transcoding + subtitle extraction
    media-scanner.js   Scan folders for SxxExx episode files
    metadata-fetcher.js  TVMaze API integration
    movie-metadata.js  IMDb API integration
    db-sync.js         SQLite backup-based sync
    sync-config.js     Sync folder config (storage/sync_config.json)

src/                   React frontend (Vite)
  App.jsx              HashRouter + routes
  main.jsx             React entry point
  context/
    PlayerContext.jsx   Player state, open/close/next, audio/subtitle switching
  components/
    VideoPlayer.jsx    Full overlay player with controls + track selector
    Navbar.jsx         Top navigation with glassmorphism blur
    NowPlaying.jsx     Persistent playback status bar
    EpisodeRow.jsx     Episode list item with 3-dot menu
    SeasonTabs.jsx     Scrollable season tab bar
    PosterCard.jsx     Series/movie poster grid card
  pages/
    Library.jsx        Series library (home)
    SeriesShow.jsx     Series detail + episode list
    SeriesNew.jsx      Add series from folder
    Movies.jsx         Movie library
    MovieShow.jsx      Movie detail
    MoviesNew.jsx      Add movies from files
    History.jsx        Watch history
    Settings.jsx       DB sync settings
  styles/
    app.css            All styles — pure black theme, Inter font

bin/
  dev                  Dev launcher (vite build + electron)
  build                Production build with auto version increment
  setup-ffmpeg         Download static ffmpeg/ffprobe for bundling

vendor/                Bundled binaries (gitignored, created by bin/setup-ffmpeg)
  ffmpeg/              Static ffmpeg + ffprobe

storage/               Local data (gitignored)
  development.sqlite3  SQLite database
  sync_config.json     Sync folder path
```

## Architecture

No HTTP server. The Electron main process handles all database access and business logic via IPC. The React renderer communicates exclusively through `window.api.*` methods exposed via `contextBridge`.

```
React (renderer)  ←— IPC (window.api.*) —→  Electron main process
                                                ├── better-sqlite3
                                                ├── ffmpeg (transcoder)
                                                └── VLC HTTP API
```

Video playback pipeline:

```
Play button → episodes:play IPC → playback:start IPC
  → ffprobe (probe streams) → ffmpeg (HEVC→H.264, VideoToolbox HW accel)
  → fragmented MP4 piped to stream:// protocol → <video> element
  → subtitle:// protocol serves time-shifted VTT
```

## Database

Schema lives in `electron/schema.sql`. Tables:

- **series** — name, slug, media_path, TVMaze metadata
- **episodes** — series_id (FK), code (SxxExx), file_path, watched, progress
- **movies** — title, slug, file_path, IMDb metadata, watched, progress
- **watch_histories** — per-episode play sessions with timestamps
- **playback_preferences** — per-series/movie audio + subtitle track preferences

## License

Private project.
