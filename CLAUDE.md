# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

Caramba is a personal media center (series + movies + player) distributed as three client apps sharing one React codebase, all backed by a Rails API server.

pnpm monorepo (`pnpm-workspace.yaml`) with four JS workspaces plus a non-workspace Rails server:

- `ui/` — `@caramba/ui`, shared React components, pages, hooks, context, and the adapter layer. Consumed by every client via `workspace:*`. Has no build step — imported as source.
- `desktop/` — `@caramba/desktop`, Electron app (macOS). `electron/` is a thin Electron main process — IPC bridge for OS-integration extras (downloads, dialogs, mDNS discovery, auto-updater, in-process libVLC engine). **No SQLite, no library scanning, no metadata fetching, no transcoder** — the Rails server owns all of that. `src/` is the Vite-built React renderer. Uses `HashRouter`.
- `web/` — `@caramba/web`, browser SPA served by Vite or by Rails in prod. Uses `BrowserRouter`. `AppAndroid.jsx` is the Android TV entrypoint selected at build time via `vite.config.android.js`.
- `android-tv/` — `@caramba/android`, Capacitor wrapper around the `web/` build for Chromecast with Google TV. Builds an APK via gradle.
- `server/` — Rails 8 API (`/api/*`) + SPA catch-all that serves the `web/` build. SQLite via `sqlite3` gem. Authoritative for everything: data, scanning, metadata, transcoding, watch state. Not part of the pnpm workspace.

## Client architecture: adapters

Each client instantiates one of two adapters in `ui/adapters/` and passes it to `ApiProvider` from `ui/context/ApiContext`. All pages/components call the API through `useApi()` — **never** call `window.api.*` or `fetch` directly inside shared `ui/` code.

- `http.js` — pure fetch against Rails `/api/*`. Used by `web/` and `android-tv/`. Detects MSE codec support and sends it on every `POST /api/playback/start` so the server can pick direct-play vs. transcode.
- `desktop.js` — wraps `http.js` and layers on Electron-only extras: native dialogs, file downloads (streams server raw files to disk), in-process libVLC engine (renders into the BrowserWindow's NSView), external VLC launcher ("Open in VLC"), mDNS server discovery, auto-updater, desktop preferences. Playback flow: server always starts the session via `http.startPlayback`; if the libVLC engine is enabled, hand the returned URL to `window.api.startEmbedVlc(url)`. Otherwise the renderer plays the URL with hls.js inside the BrowserWindow.

`capabilities` objects (`desktopCapabilities`, `httpCapabilities`) gate UI features: "Download", "Open externally", "Settings", "Updater", "VLC library", embedded VLC engine, etc. The android-tv build also opts into `useNativePlayerCodecs` on its `http.js` to advertise ExoPlayer's broader codec support.

## Desktop Electron internals

Thin client. The main process is small (~140 LOC in `electron/main.js`):
- BrowserWindow with `transparent: true` (so libVLC's NSView, when added behind Chromium's WebContents subview, is visible through the React UI's transparent body region), `titleBarStyle: hiddenInset`, traffic lights at 16,16.
- Power-save: libVLC playback prevents display sleep via the `prevent-display-sleep` blocker handled by the embed module.
- Security: blocks renderer navigation away from origin; opens external `http(s)://` links in system browser via `shell.openExternal`.
- No custom protocol handlers, no tray, no dock menu, no deep links, no file associations.

IPC modules in `electron/ipc/*.js` — one file per surface area, each exports `register()`:
- `settings.js` — server URL config + desktop preferences.
- `dialogs.js` — file/folder pickers (downloads destination).
- `vlc.js` — both engines: in-process libVLC embed (`vlc:embed*` channels) and external VLC subprocess for "Open in VLC" / "Open in default app".
- `updater.js` — GitHub Releases polling (`updater.js` service), download + install.
- `downloads.js` — streams `/api/media/{episodes,movies}/:id` to disk with progress events.
- `discovery.js` — mDNS browse for Caramba servers on the LAN.

Services in `electron/services/*.js`:
- `vlc-embed-player.js` — drives the in-process libVLC native module (see below). Polls libVLC for state at 4Hz, emits `state` / `tracks` / `ended` events, runs stall detection (no media-time advance for 2.5s of wall-clock while playing → Sentry breadcrumb).
- `libvlc-player.js` — external VLC subprocess fallback (random per-session HTTP password, used by "Open in VLC").
- `preferences.js` — desktop-side prefs (server URL, player engine choice, downloads folder).
- `track-selection.js` (+ test) — language-preference logic for picking audio/subtitle tracks at the JS layer.
- `discovery.js` — Bonjour/mDNS browser.
- `updater.js` — GitHub Releases checker + DMG download.

Native module `electron/native/vlc-embed/`:
- `src/binding.mm` — Objective-C++ N-API wrapping libVLC. Receives the BrowserWindow's NSView pointer via `BrowserWindow.getNativeWindowHandle()`, calls `libvlc_media_player_set_nsobject(player, parentNSView)` so libVLC creates a video subview *inside* the BrowserWindow. Then `vlcSendBehind` walks the parent's subviews, finds libVLC's vout subview by class prefix `VLC*`, and reorders it `NSWindowBelow` relative to Chromium's WebContents subview. Result: video and React UI in the same NSView in the same BrowserWindow.
- `binding.gyp` — links `libvlc.dylib` from `desktop/vendor/vlc-${arch}/lib/`. `desktop/bin/setup-vlc` fetches the libVLC bundle (gitignored).

## Rails server essentials

- API lives entirely under `namespace :api` in `server/config/routes.rb`. Everything else falls through to `spa#index` which serves the built React `index.html`.
- HLS playback endpoints: `POST /api/playback/start` creates a session given the file path + `codecSupport: { h264, hevc, hevc10, audio: {...} }` + `forceTranscode`. Server picks one of four strategies (`direct_play`, `direct_stream`, `audio_transcode`, `full_transcode`) and returns either a direct file URL (`/api/playback/file/:session_id`, byte-range supported) or an HLS manifest URL (`/api/playback/hls/:session_id/playlist.m3u8`).
- `report_progress` writes back to `WatchHistory` + `Episode`/`Movie`.
- Services: `transcoder_service.rb` (ffmpeg HLS), `tvmaze_service.rb`, `imdb_api_service.rb`, `media_scanner_service.rb`, `movie_parser_service.rb`, `tech_probe_service.rb` (cached ffprobe), `nfo_parser_service.rb`, `library_watcher_service.rb`.
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

The desktop build symlinks `@electron/rebuild` to `electron-rebuild` because electron-builder looks for the old name but pnpm installs the scoped package. `bin/setup-ffmpeg` fetches the macOS ffmpeg binaries into `desktop/vendor/` (gitignored). `desktop/bin/setup-vlc` fetches libVLC + plugins into `desktop/vendor/vlc-${arch}/`.

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
- New cross-client features go in `ui/` and call into the shared adapter via `useApi()`. The Rails server owns the data and behavior; `http.js` is the canonical API surface; `desktop.js` only adds Electron-only extras (downloads, dialogs, mDNS, updater, embed VLC engine, native VLC library control). A capability missing from `http.js` should be a `noopAsync`, not absent — desktop depends on the full shape.
- Feature gates in `ui/` use the `capabilities` object from each adapter (`desktopCapabilities`, `httpCapabilities`, plus the android-tv build's overrides). Add to both when introducing a new capability.
- The desktop renderer is `transparent: true` so libVLC can render a video subview behind Chromium. Do not assume an opaque body background in shared `ui/` code.
- The libVLC embed engine in `desktop/electron/native/vlc-embed/` is macOS-only (Objective-C++ + Cocoa). Don't reference its IPC channels (`vlc:embed*`) from `ui/` without a capability check (`capabilities.hasVlcEmbedPlayer`).
- Playback request body shape (`POST /api/playback/start`) is the contract between every client and the server: `{ filePath, startTime, prefs, codecSupport, forceTranscode }`. New clients build their own `codecSupport` from MSE probes (or hardcode for native players like ExoPlayer); server picks strategy from there.
