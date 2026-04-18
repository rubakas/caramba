# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Caramba is a personal media center (series + movies + player) distributed as three client apps sharing one React codebase, optionally backed by a Rails API.

pnpm monorepo (`pnpm-workspace.yaml`) with four JS workspaces plus a non-workspace Rails server:

- `ui/` — `@caramba/ui`, shared React components, pages, hooks, context, and the adapter layer. Consumed by every client via `workspace:*`. Has no build step — imported as source.
- `desktop/` — `@caramba/desktop`, Electron app (macOS). `electron/` is the main process (IPC + services + SQLite). `src/` is the Vite-built React renderer. Uses `HashRouter`.
- `web/` — `@caramba/web`, browser SPA served by Vite or by Rails in prod. Uses `BrowserRouter`. `AppAndroid.jsx` is the Android TV entrypoint selected at build time via `vite.config.android.js`.
- `android-tv/` — `@caramba/android`, Capacitor wrapper around the `web/` build for Chromecast with Google TV. Builds an APK via gradle.
- `server/` — Rails 8 API (`/api/*`) + SPA catch-all that serves the `web/` build. SQLite via `sqlite3` gem. Not part of the pnpm workspace.

## Client architecture: adapters

Each client instantiates one of three adapters in `ui/adapters/` and passes it to `ApiProvider` from `ui/context/ApiContext`. All pages/components call the API through `useApi()` — **never** call `window.api.*` or `fetch` directly inside shared `ui/` code.

- `local.js` — Electron-only; calls `window.api.*` (IPC bridge in `desktop/electron/preload.js`).
- `http.js` — pure fetch against Rails `/api/*`; detects MSE codec support so the server can pick direct-play vs. transcode.
- `hybrid.js` — desktop "API mode". Prefers HTTP for data, falls back to local IPC on disconnect. Playback uses the local ffmpeg transcoder when the media file is reachable on the filesystem (network mount), otherwise streams HLS from the server. File pickers, VLC, downloads, updates, and settings are **always local**. Emits `onConnectionChange` via a 30s `/api/health` poll.

`capabilities` objects (`localCapabilities`, `httpCapabilities`, androidTvCapabilities in `web/src/App.jsx`) gate UI features like "Add", "Download", "Open externally", "Settings".

## Desktop Electron internals

- `electron/main.js` — window, custom `stream://` and `subtitle://` protocols, registers all IPC modules.
- `electron/ipc/*.js` — one file per domain (series, episodes, movies, playback, history, discover, dialogs, downloads, settings, updater). Each exports `register()`.
- `electron/services/*.js` — `transcoder.js` (spawns ffmpeg with VideoToolbox hw accel), `db-sync.js` (shared-folder sync), `metadata-fetcher.js` + `movie-metadata.js` (TVMaze / IMDb), `media-scanner.js`, `updater.js` (GitHub Releases), `vlc-player.js` (external VLC fallback with per-session random password).
- `electron/db.js` + `electron/schema.sql` — better-sqlite3 with WAL. DB lives in `userData/storage` when packaged, `desktop/storage/` in dev (gitignored).
- Subtitle handling in `main.js` caches the raw VTT and serves time-shifted versions through the `subtitle://` protocol so seeking doesn't reload the file.

## Rails server essentials

- API lives entirely under `namespace :api` in `server/config/routes.rb`. Everything else falls through to `spa#index` which serves the built React `index.html`.
- HLS playback endpoints: `POST /api/playback/start` creates a session; the player then fetches `/api/playback/hls/:session_id/playlist.m3u8` and segments. `report_progress` writes back to `WatchHistory` + `Episode`/`Movie`.
- Services: `transcoder_service.rb` (ffmpeg), `tvmaze_service.rb`, `imdb_api_service.rb`, `media_scanner_service.rb`, `movie_parser_service.rb`.
- Uses `rails-omakase` style; `webmock` in test group — tests must stub external HTTP.

## Running locally

Use the `bin/` wrappers — they launch foreman with the right Procfile. Foreman is auto-installed (`gem install foreman`) on first run.

```bash
bin/desktop            # Rails on :3001 + Vite :5173 + Electron
bin/web                # Rails on :3001 + Vite :3000 (host mode)
bin/android            # Rails + Vite + Capacitor live-reload to AVD "Television_4K" (override via CARAMBA_AVD)
bin/android-device     # Same but to a real ADB device (override via CARAMBA_DEVICE / CARAMBA_HOST_IP)
```

Electron-only dev (no Rails): `cd desktop && pnpm dev` then `pnpm electron` in another shell.

Rails-only: `cd server && bin/rails server -p 3001`.

## Building / releasing

Versioning is centralized in the **root** `package.json`. `desktop/bin/build` auto-bumps the patch version and commits it with the bare version string as the message (e.g. `v1.3.0`) before building. Don't bump manually and don't edit workspace `package.json` versions.

```bash
bin/build                    # Both desktop (DMG) and android-tv (APK)
bin/build --desktop          # Desktop only
bin/build --android-tv       # Android TV only; reads version, does not bump
bin/build --publish          # Build + publish both to GitHub Releases
```

The desktop build symlinks `@electron/rebuild` to `electron-rebuild` because electron-builder looks for the old name but pnpm installs the scoped package. `bin/setup-ffmpeg` fetches the macOS ffmpeg binaries into `desktop/vendor/` (gitignored).

## Rails tests & CI

```bash
cd server
bin/rails test                          # full Minitest suite
bin/rails test test/models/series_test.rb           # single file
bin/rails test test/models/series_test.rb:42        # single test at line 42
bin/ci                                  # rubocop + bundler-audit + brakeman + tests + seed replant
bin/rubocop -a                          # autocorrect
```

There is no JS test suite.

## Conventions to match

- Rails API responses are consumed in camelCase on the client — controllers shape JSON explicitly (see `playback_controller.rb#preferences`). Match that style when adding endpoints.
- New cross-client features go in `ui/` and gain methods on all three adapters (`local`, `http`, `hybrid`) and on `preload.js`. A capability missing from `http.js` should be a `noopAsync`, not absent — hybrid depends on the full shape.
- The `stream://` and `subtitle://` custom protocols are Electron-only. Don't reference them from `ui/` code without a capability check.
- `hybrid.js` tracks `playbackMode` (`local` vs. `remote`) for the active session — changes to playback lifecycle must update it on both start and stop paths.
