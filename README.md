# Caramba

Apple TV+ inspired episode tracker and media player built with Electron, React and SQLite.

Track TV series and movies, manage watch progress across devices with DB sync, and play media files directly in the app using ffmpeg hardware-accelerated transcoding.

## Features

- **Series Tracker** — scan a folder of TV episodes (SxxExx naming), auto-fetch metadata from TVMaze, track watched/unwatched state per episode, resume from where you left off, auto-play next episode
- **Movies** — add movie files, fetch metadata + posters from IMDb, track progress
- **Discover** — browse trending and popular series/movies, add to library
- **In-App Video Player** — plays HEVC/H.265 MKV files via ffmpeg transcoding (HEVC→H.264 with VideoToolbox hardware acceleration on macOS, libx264 on Linux), with subtitle support (VTT extraction + shifting), audio/subtitle track selection, and playback preferences saved per series/movie
- **VLC Integration** — open any file in VLC with HTTP-based progress tracking (polls VLC's HTTP API)
- **DB Sync** — sync your SQLite database to a shared folder (iCloud, Dropbox, etc.) so progress carries across machines. Uses `sqlite3 .backup` for safe copies, periodic sync every 30s
- **NowPlaying Bar** — persistent bottom bar showing current playback state for both in-app and VLC playback
- **Auto-Updater** — checks GitHub Releases for new versions, downloads with progress + SHA256 verification, installs and relaunches automatically
- **Liquid Glass UI** — Apple-style refractive glassmorphism using `@hashintel/refractive` across navbar, cards, modals, toasts, and player controls

## Tech Stack

| Layer    | Technology                                              |
| -------- | ------------------------------------------------------- |
| Frontend | React 19, React Router 7 (HashRouter), Vite 6           |
| Backend  | Electron 33, better-sqlite3                              |
| Player   | ffmpeg (VideoToolbox / libx264), HTML5 `<video>`         |
| UI       | @hashintel/refractive (Liquid Glass), CSS custom props   |
| Metadata | TVMaze (series), imdbapi.dev (movies)                    |
| Package  | electron-builder (DMG, AppImage, deb)                    |

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

The build script auto-increments the patch version in `package.json` and commits the bump as `vX.Y.Z`. If the last commit is already a version bump, the version stays the same for idempotent rebuilds.

Output goes to `dist/` — look for `.dmg`, `.AppImage`, or `.deb` files.

### Publishing

Pass `--publish` to upload built artifacts to GitHub Releases via the `gh` CLI:

- Creates a new release tagged `vMAJOR.MINOR.PATCH` with the latest commit message as notes
- If the release already exists (idempotent rebuild), overwrites the assets
- Requires `gh` to be installed and authenticated (`gh auth login`)

## Auto-Updater

The app includes a custom auto-updater (no `electron-updater` dependency). On startup, it checks `https://api.github.com/repos/rubakas/caramba/releases/latest` for a newer version.

- Detects platform-specific asset (`.dmg` for macOS, `.AppImage` for Linux)
- Verifies SHA256 checksum if a `CHECKSUMS.txt` asset is attached to the release
- Downloads to a temp directory with progress reporting
- **macOS install**: mounts DMG, stages the `.app` to a temp dir, spawns a detached shell script that waits for the app to quit, copies the new `.app` to `/Applications/`, and relaunches
- **Linux install**: replaces the AppImage binary in-place, relaunches

The update UI (`UpdatePrompt`) shows phases: available → downloading (with progress bar) → ready to install.

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
    discover.js        Discover/trending metadata from external APIs
    updater.js         Auto-update check, download, install IPC handlers
  services/
    transcoder.js      ffmpeg HEVC→H.264 transcoding + subtitle extraction
    media-scanner.js   Scan folders for SxxExx episode files
    metadata-fetcher.js  TVMaze API integration
    movie-metadata.js  IMDb API integration
    db-sync.js         SQLite backup-based sync
    sync-config.js     Sync folder config (storage/sync_config.json)
    updater.js         GitHub Releases update checker + installer

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
    ToastContainer.jsx Toast notifications
    UpdatePrompt.jsx   Auto-update banner (check, download, install)
  pages/
    Library.jsx        Series library (home)
    SeriesShow.jsx     Series detail + episode list
    SeriesNew.jsx      Add series from folder
    Movies.jsx         Movie library
    MovieShow.jsx      Movie detail
    MoviesNew.jsx      Add movies from files
    Discover.jsx       Trending/popular series and movies
    History.jsx        Watch history
    Settings.jsx       DB sync settings
    Playground.jsx     Dev-only glass parameter tuning (dev mode only)
  config/
    glass.json         Refractive glass config (defaults + per-component)
    useGlassConfig.js  Hook to resolve glass config with defaults
  styles/
    app.css            All styles — pure black theme, Apple system font stack

bin/
  dev                  Dev launcher (vite build + electron)
  build                Production build with auto version increment
  publish              Upload artifacts to GitHub Releases via gh CLI
  setup-ffmpeg         Download static ffmpeg/ffprobe for bundling (--mac / --linux)

vendor/                Bundled binaries (gitignored, created by bin/setup-ffmpeg)
  ffmpeg/              macOS ARM static ffmpeg + ffprobe
  ffmpeg-linux/        Linux x64 static ffmpeg + ffprobe

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
