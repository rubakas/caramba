# Caramba

Episode tracker and media player built with Electron, React, and SQLite. Track TV series and movies, manage watch progress, and play media files with hardware-accelerated transcoding.

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
cd desktop
npm run dev

# Build for macOS
npm run build

# Build and publish to GitHub Releases
npm run build -- --publish
```

## Key Features

- **Series & Movies** — track watch progress for TV episodes and movies
- **Video Playback** — HEVC/H.264 transcoding via ffmpeg with hardware acceleration
- **Metadata** — auto-fetch series metadata from TVMaze, movies from IMDb
- **Database Sync** — sync progress across devices via shared folder
- **Discover** — browse trending series and movies
- **Auto-Updater** — checks GitHub Releases for new versions

## Project Structure

```
desktop/               Electron app (macOS desktop client)
  electron/            Electron main process + IPC handlers
    main.js            App entry, window setup
    preload.js         IPC API bridge
    db.js              SQLite helpers
    ipc/               IPC handlers (series, episodes, movies, etc.)
    services/          Business logic (transcoding, metadata fetch, sync)
  src/                 React frontend (Vite)
    ui/                Components and pages
    context/           React context (player state, etc.)
    config/            UI configuration
  storage/             Local database and config (gitignored)
  vendor/              ffmpeg binaries (gitignored)

server/                Ruby on Rails backend (API)
web/                   Web version (React)
ui/                    Shared UI components
```

## Tech Stack

- **Frontend** — React, Vite, React Router
- **Desktop** — Electron, better-sqlite3
- **Backend** — Ruby on Rails
- **Media** — ffmpeg (VideoToolbox acceleration), HTML5 video
- **Metadata** — TVMaze API, IMDb API
- **Build** — electron-builder

## Prerequisites

- Node.js >= 18
- VLC (optional, for "Open in VLC" feature)

## License

Private project.
