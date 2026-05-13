# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Caramba is a personal media center (series + movies + player) distributed as three client apps sharing one React codebase, all backed by a Rails API server.

pnpm monorepo (`pnpm-workspace.yaml`) with five JS workspaces plus a non-workspace Rails server:

- `ui/` — `@caramba/ui`, shared React components, pages, hooks, context, and the adapter layer. Consumed by every client via `workspace:*`. Has no build step — imported as source.
- `desktop/` — `@caramba/desktop`, Electron app (macOS). `electron/` is a thin Electron main process — IPC bridge for OS-integration extras (downloads, dialogs, mDNS discovery, auto-updater, external VLC subprocess). **No SQLite, no library scanning, no metadata fetching, no transcoder, no native player engine** — the Rails server owns all data + ffmpeg orchestration, and playback runs through the same Jellyfin Player JS runtime as the browser. `src/` is the Vite-built React renderer. Uses `HashRouter`.
- `web/` — `@caramba/web`, browser SPA served by Vite or by Rails in prod. Uses `BrowserRouter`. `AppAndroid.jsx` is the Android TV entrypoint selected at build time via `vite.config.android.js`.
- `android-tv/` — `@caramba/android`, Capacitor wrapper around the `web/` build for Chromecast with Google TV. Builds an APK via gradle.
- `player/` — `@jellyfin-rails/player`, vendored from the jellyfin-rails port. TypeScript playback runtime: HTML5 `<video>` + hls.js + Safari native HLS + subtitle handling (libass/libpgs). Imported as source via Vite. Consumed by `ui/components/VideoPlayer.jsx`.
- `server/` — Rails 8 API (`/api/*`) + SPA catch-all that serves the `web/` build. SQLite via `sqlite3` gem. Authoritative for data, scanning, metadata, watch state. **ffmpeg orchestration is delegated to the `jellyfin-rails` engine at `server/vendor/jellyfin-rails/`** (Caramba is the canonical home; the engine may be extracted back into a standalone gem later), mounted internally at `/_jellyfin`. jellyfin-ffmpeg binaries live at `server/vendor/ffmpeg/<platform>-<arch>/`, downloaded by `server/bin/setup-ffmpeg`. Not part of the pnpm workspace.

## Client architecture: adapters

Each client instantiates one of two adapters in `ui/adapters/` and passes it to `ApiProvider` from `ui/context/ApiContext`. All pages/components call the API through `useApi()` — **never** call `window.api.*` or `fetch` directly inside shared `ui/` code.

- `http.js` — pure fetch against Rails `/api/*`. Used by `web/` and `android-tv/`. Detects MSE codec support and sends it on every `POST /api/playback/start` so the server can pick direct-play vs. transcode.
- `desktop.js` — wraps `http.js` and layers on Electron-only extras: native dialogs, file downloads (streams server raw files to disk), external VLC launcher ("Open in VLC"), mDNS server discovery, auto-updater, desktop preferences. Playback flows through the same `http.startPlayback` and the same Jellyfin Player JS runtime in the renderer — there is no alternate engine on desktop.

`capabilities` objects (`desktopCapabilities`, `httpCapabilities`) gate UI features: "Download", "Open externally", "Settings", "Updater", "VLC library", etc.

Each client builds a Jellyfin-compatible `DeviceProfile` (`ui/adapters/device-profile.js`) and sends it with every `POST /api/playback/start`. The Rails shim translates it via `CarambaClientProfile.build(...)` into a `Jellyfin::Playback::ClientProfile` that the engine's `Decision` module consumes. Builders: `buildBrowserProfile` (MSE probes), `buildDesktopProfile` (delegates to the browser builder — the renderer is Chromium), `buildAndroidTvProfile` (ExoPlayer hardcoded coverage).

## Player runtime (Jellyfin Player JS)

The shared playback runtime is `@jellyfin-rails/player`, instantiated in `ui/components/VideoPlayer.jsx` against a `<div>` mount inside the React overlay. The Player owns:
- `<video>` element + hls.js (or Safari native HLS) wiring
- subtitle handling (text + libass-wasm for ASS/SSA, libpgs for PGS bitmaps)
- HLS error recovery, stall watchdog, Safari prefetch hack
- progress/play/pause/ended/error events

The React overlay (Caramba-owned: popovers, TV mode D-pad, seek bar, subtitle appearance toggles, dev pill) renders on top of the player's mount and proxies user input through the Player API (`player.seek`, `player.play`, `player.pause`, `player.setVolume`, `player.setActiveSubtitleTrack`). Audio/subtitle track switches re-issue `POST /api/playback/start` so the engine signs a fresh transcode token with the chosen track baked in.

## Desktop Electron internals

Thin client. The main process is small (`electron/main.js`):
- Opaque BrowserWindow with `titleBarStyle: hiddenInset`, traffic lights at 16,16.
- Security: blocks renderer navigation away from origin; opens external `http(s)://` links in system browser via `shell.openExternal`.
- No custom protocol handlers, no tray, no dock menu, no deep links, no file associations.

IPC modules in `electron/ipc/*.js` — one file per surface area, each exports `register()`:
- `settings.js` — server URL config + desktop preferences.
- `dialogs.js` — file/folder pickers (downloads destination).
- `vlc.js` — external VLC subprocess for "Open in VLC" / "Open in default app" (the user's installed VLC.app).
- `updater.js` — GitHub Releases polling (`updater.js` service), download + install.
- `downloads.js` — streams `/api/media/{episodes,movies}/:id` to disk with progress events.
- `discovery.js` — mDNS browse for Caramba servers on the LAN.

Services in `electron/services/*.js`:
- `libvlc-player.js` — external VLC subprocess control (random per-session HTTP password, used by "Open in VLC").
- `preferences.js` — desktop-side prefs (server URL, downloads folder).
- `track-selection.js` (+ test) — language-preference logic for picking audio/subtitle tracks at the JS layer.
- `discovery.js` — Bonjour/mDNS browser.
- `updater.js` — GitHub Releases checker + DMG download.

## Rails server essentials

- API lives entirely under `namespace :api` in `server/config/routes.rb`. Everything else falls through to `spa#index` which serves the built React `index.html`.
- The `jellyfin-rails` engine is mounted at `/_jellyfin` (internal — clients hit `/api/playback/*` which shims to it). The engine owns ffmpeg orchestration (`Jellyfin::Transcoding::TranscodeManager`), token signing (`Jellyfin::Transcoding::Token`), HLS master/variant/segment serving, WebVTT subtitle segmentation, trickplay, hwaccel (VideoToolbox on macOS), tonemap, and the subtitle burn-in path.
- Caramba's `api/playback_controller.rb` keeps four actions: `start`, `stop`, `report_progress`, `preferences` (+ `save_preferences`). The `start` action probes the file via `TechProbeService`, picks audio + subtitle tracks (the rich language/codec/channels precedence stays in Caramba), translates the client's DeviceProfile via `CarambaClientProfile`, calls `Jellyfin::Playback::PlaybackInfo.for(...)`, and returns the engine's URLs in Caramba's existing response shape (`{ hlsUrl, streamUrl, sessionId, audioStreams, subtitleStreams, activeAudioIndex, ... }`). Strategy labels (`direct_play` / `direct_stream` / `audio_transcode` / `full_transcode`) are derived for the dev-mode pill.
- `report_progress` writes back to `WatchHistory` + `Episode`/`Movie`. `stop` cancels the engine job via `TranscodeManager.instance.cancel!`.
- Caramba services: `tvmaze_service.rb`, `imdb_api_service.rb`, `media_scanner_service.rb`, `movie_parser_service.rb`, `tech_probe_service.rb` (delegates to `Jellyfin::MediaEncoder::Probe`, caches on Episode/Movie `tech_metadata`), `nfo_parser_service.rb`, `library_watcher_service.rb`, `caramba_client_profile.rb`.
- Uses `rails-omakase` style; `webmock` in test group — tests must stub external HTTP.

## Running locally

Use the `bin/` wrappers — they launch foreman with the right Procfile. Foreman is auto-installed (`gem install foreman`) on first run.

```bash
bin/desktop            # Rails on :3001 + Vite :5173 + Electron
bin/web                # Rails on :3001 + Vite :3000 (host mode)
bin/android            # Rails + Vite + Capacitor live-reload to AVD "Television_4K" (override via CARAMBA_AVD)
bin/android-device     # Same but to a real ADB device (override via CARAMBA_DEVICE / CARAMBA_HOST_IP)
```

Electron-only dev (no Rails) is no longer a supported mode — the desktop is a pure client and needs a running server. In dev, `bin/desktop` brings up Rails + Vite + Electron under foreman.

Rails-only: `cd server && bin/rails server -p 3001`.

## Building / releasing

Versioning is centralized in the **root** `package.json`. `desktop/bin/build` auto-bumps the patch version and commits it with the bare version string as the message (e.g. `v1.3.0`) before building. Don't bump manually and don't edit workspace `package.json` versions.

```bash
bin/build                    # Both desktop (DMG) and android-tv (APK)
bin/build --desktop          # Desktop only
bin/build --android-tv       # Android TV only; reads version, does not bump
bin/build --publish          # Build + publish both to GitHub Releases
```

The desktop build symlinks `@electron/rebuild` to `electron-rebuild` because electron-builder looks for the old name but pnpm installs the scoped package. The server uses the system `ffmpeg` / `ffprobe` (overridable via `FFMPEG_PATH` / `FFPROBE_PATH` env vars).

## Rails tests & CI

```bash
cd server
bin/rails test                          # full Minitest suite
bin/rails test test/models/series_test.rb           # single file
bin/rails test test/models/series_test.rb:42        # single test at line 42
bin/ci                                  # rubocop + bundler-audit + brakeman + tests + seed replant
bin/rubocop -a                          # autocorrect
```

There is no JS test suite (a couple of `*.test.js` files exist for narrow utility code — `track-selection.test.js`, `http.test.js` — but no broad runner).

## Conventions to match

- Rails API responses are consumed in camelCase on the client — controllers shape JSON explicitly (see `playback_controller.rb#preferences`). Match that style when adding endpoints.
- New cross-client features go in `ui/` and call into the shared adapter via `useApi()`. The Rails server owns the data and behavior; `http.js` is the canonical API surface; `desktop.js` only adds Electron-only extras (downloads, dialogs, mDNS, updater, external VLC). A capability missing from `http.js` should be a `noopAsync`, not absent — desktop depends on the full shape.
- Feature gates in `ui/` use the `capabilities` object from each adapter (`desktopCapabilities`, `httpCapabilities`, plus the android-tv build's overrides). Add to both when introducing a new capability.
- Playback request body shape (`POST /api/playback/start`) is the contract between every client and the server: `{ filePath, startTime, prefs, deviceProfile }`. Each client builds its own `deviceProfile` (see `ui/adapters/device-profile.js`); the server translates it via `CarambaClientProfile` and the engine picks the delivery method. No `forceTranscode` flag — the profile is the only authority.
- The Jellyfin engine at `server/vendor/jellyfin-rails/` is Caramba's own — edit in place, add RSpec specs alongside (`cd server/vendor/jellyfin-rails && bundle exec rspec`). Before changing any engine code, compare against upstream Jellyfin C# at `/Users/cupatea/code/jellyfin/jellyfin/` — most port bugs are omissions, and upstream is authoritative. Cite the upstream `file:line` in a comment next to the fix.
