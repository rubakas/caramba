# E2E Testing Harness — Design

**Date:** 2026-04-25
**Status:** Awaiting user review
**Author:** Vladyslav Davydenko (with Claude)

## Goal

A Playwright-based E2E harness that lets Claude reproduce playback bugs and detect regressions on the user's real local library — without requiring the user to manually open the app, click through to playback, and paste console logs.

When something breaks (especially high-bitrate playback, the recurring pain), the workflow becomes:

1. User: "Dune.mkv stalls 10s in on the desktop app — fix it."
2. Claude: runs `bin/test-playback /path/to/Dune.mkv`, gets a `summary.json` with the strategy chosen, ffmpeg stderr, hls.js fatal events, video element state at failure — then patches `desktop/electron/services/transcoder.js` accordingly.

## Scope

**In scope**

- Playwright project covering two clients: `@caramba/web` (Chromium) and `@caramba/desktop` (Electron, hybrid/API mode)
- Two test families behind tags:
  - `@smoke` — breadth-first regression checks on shows / movies / playback. Runtime library discovery — picks first item from `/api/shows` and `/api/movies`.
  - `@playback` — deep capture for one specific file/slug, parameterised by `CARAMBA_TEST_TARGET`. Used for bug reproduction.
- Always-on per-test diagnostic bundle: `summary.json`, browser console, Electron main console, server transcoder log, network HAR, screenshots, Playwright video, trace.zip.
- Custom Playwright reporter that emits a Claude-friendly `summary.json` per test.
- Probe-and-fallback server lifecycle: reuse Rails on :3001 if running, else auto-start it.
- Read-only behaviour against the dev DB — `report_progress` is a no-op when the request carries `X-Test-Run: 1`. Watch history, episode progress, movie progress are not mutated by test runs.
- A `bin/test-playback <target>` shortcut for the common reproducer case.
- Sustained playback assertion with checkpoint sweep (30s, samples at 5/15/25s, plus one mid-stream seek).
- Isolated Electron `userData` (temp dir per run) so tests don't stomp on the user's real `desktop/storage/api_config.json`.

**Out of scope**

- Android-TV (Capacitor APK) E2E
- Electron in pure local mode (own SQLite, IPC-only, no Rails)
- Strategy-specific tests (separate specs per `direct_play` / `audio_transcode` / `full_transcode`) — tests run whatever the discovered/passed target needs
- CI integration — these tests depend on the user's personal library; CI has none
- Fixture media checked into the repo
- Pinned target config file
- Performance / benchmark assertions (e.g. ffmpeg encode FPS thresholds)

## Decisions

| # | Decision | Chosen | Why |
|---|---|---|---|
| 1 | Test families | One harness with `@smoke` and `@playback` tags | Both motivations (regression + reproducer) addressed from day one; minimal extra config over a single-family harness |
| 2 | Target identification | Runtime discovery via `/api/shows` and `/api/movies` (no fixture management) | User explicitly wants tests to use the real local library, not committed sample media |
| 3 | Electron mode | Hybrid (API) only | Single backend (Rails) drives both suites' data; hybrid still uses `transcoder.js` for local files, so both transcoders stay covered |
| 4 | Diagnostic capture | Always-on bundle (summary + logs + HAR + screenshots + video + trace) | Disk is cheap; debugging is the whole point. No "I'll re-run with --verbose" friction |
| 5 | Server lifecycle | Probe-and-fallback (reuse :3001 if up, else spawn) | Same command works whether `bin/desktop` is already running or not |
| 6 | Playback assertion | Sustained 30s + checkpoint sweep at 5/15/25s + one mid-stream seek | Catches stall-after-N-seconds (the high-bitrate failure mode); seek-under-load regressions; closely mirrors manual reproduction |
| 7 | Workspace placement | New `tests/` pnpm workspace | Isolates Playwright deps; allows `pnpm --filter @caramba/tests test`; matches existing four-workspace layout |
| 8 | Test-mode write protection | `X-Test-Run: 1` header → server skips writes in `report_progress`, `Api::EpisodesController#play` / `#toggle`, `Api::MoviesController#play` / `#toggle` (each method short-circuits with a stub response) | Tests don't mutate the user's actual watch history, watched flags, or `WatchHistory` records; one shared `before_action` lifted into `Api::BaseController` keeps the change small |
| 9 | Electron userData isolation | Env var `CARAMBA_STORAGE_PATH` overrides hard-coded `desktop/storage/` in `db.js` and `services/api-config.js`; tests pass a freshly-created temp dir | Tests can pre-write `api_config.json` to enable hybrid mode without touching the user's real settings |
| 10 | Language | Plain JS (no TypeScript) | Matches the rest of the repo (only `android-tv/*.ts` is TS); no toolchain change |

## Architecture

```
tests/
  package.json                      # @caramba/tests
  playwright.config.js
  electron/
    launch.js                       # _electron.launch() with isolated userData, hybrid mode pre-configured
  fixtures/
    base.js                         # Playwright test() extended with library, diagnostics, mainConsole, serverLog
    library.js                      # API helpers: probeFirstShow(), probeFirstMovie(), probeFirstEpisode()
    diagnostics.js                  # collects browser console + video state + hls events; emits summary.json
    server.js                       # probe-and-start Rails on :3001
    serverLog.js                    # tail server/log/development.log between byte offsets
    target.js                       # resolves CARAMBA_TEST_TARGET env into { kind, slug?, filePath? }
    asserts.js                      # assertPlayback(page, opts) — the C-level assertion
  specs/
    web/
      smoke.shows.spec.js           # @smoke
      smoke.movies.spec.js          # @smoke
      playback.spec.js              # @playback
    electron/
      smoke.launch.spec.js          # @smoke (launch + settings + library list)
      smoke.playback.spec.js        # @smoke (full play-from-library flow)
      playback.spec.js              # @playback
  reporters/
    diagnostic-summary.js           # custom Playwright reporter writing summary.json per test
  test-results/                     # gitignored output
  playwright-report/                # gitignored output
```

### Two Playwright projects

```js
// playwright.config.js (sketch)
{
  projects: [
    { name: 'web',      testDir: './specs/web',      use: { browserName: 'chromium', baseURL: 'http://localhost:3000' } },
    { name: 'electron', testDir: './specs/electron', use: { /* electron via fixtures */ } },
  ],
  reporter: [['html'], ['./reporters/diagnostic-summary.js']],
  use: { trace: 'on', video: 'on', screenshot: 'only-on-failure' },
}
```

`web` project: Chromium pointed at `http://localhost:3000` (web Vite dev server) which proxies `/api/*` to Rails on :3001.
`electron` project: tests get an `electronApp` fixture (see Electron launch below); no shared baseURL.

Both projects use the same `library.js` / `diagnostics.js` / `asserts.js` helpers; specs differ only in *how the player is reached*.

### Electron hybrid-mode launch

`tests/electron/launch.js`:

1. Create a temp dir, e.g. `mktemp -d /tmp/caramba-test-XXXX`. Inside it create a `storage/` subdirectory.
2. Write `<temp>/storage/api_config.json`:
   ```json
   { "enabled": true, "server_url": "http://localhost:3001", "local_playback": true }
   ```
3. Launch Electron via Playwright's `_electron.launch()`:
   ```js
   const app = await _electron.launch({
     args: ['./electron/main.js'],
     cwd: path.resolve(__dirname, '../../desktop'),
     env: {
       ...process.env,
       CARAMBA_STORAGE_PATH: path.join(temp, 'storage'),
       VITE_DEV_URL: 'http://localhost:5173', // if Vite is running, hot-reload renderer
     },
   })
   ```
4. `app.firstWindow()` → `Page` for browser-style assertions.
5. Subscribe to `app.on('console', ...)` to capture main-process stdout/stderr into `console.electron-main.log`.
6. After the test, kill the app and `rm -rf` the temp dir.

This requires a small change in `desktop/electron/db.js` and `desktop/electron/services/api-config.js` to honour `process.env.CARAMBA_STORAGE_PATH` when set, instead of the hard-coded dev path. Production path (`app.getPath('userData')`) is untouched.

### Library probes (`fixtures/library.js`)

```js
export async function probeFirstMovie(apiBase) {
  const res = await fetch(`${apiBase}/api/movies`)
  const movies = await res.json()
  if (!movies.length) throw new Error('Library has no movies — add at least one to dev DB')
  return movies[0]  // { slug, title, filePath, ... }
}

export async function probeFirstShow(apiBase) {
  const res = await fetch(`${apiBase}/api/shows`)
  const shows = await res.json()
  if (!shows.length) throw new Error('Library has no shows — add at least one to dev DB')
  return shows[0]
}

export async function probeFirstEpisode(apiBase) {
  const show = await probeFirstShow(apiBase)
  const full = await fetch(`${apiBase}/api/shows/${show.slug}/full`).then(r => r.json())
  for (const season of full.seasons || []) {
    const ep = (season.episodes || []).find(e => e.filePath)
    if (ep) return { ...ep, showSlug: show.slug }
  }
  throw new Error(`Show ${show.slug} has no episodes with file paths`)
}

export async function resolveTarget(apiBase) {
  const t = process.env.CARAMBA_TEST_TARGET
  if (!t) return { kind: 'auto' }  // smoke uses probeFirstMovie
  if (t.startsWith('file:')) return { kind: 'file', filePath: t.slice(5) }
  if (t.startsWith('episode:')) return { kind: 'episode', id: t.slice(8) }
  if (t.startsWith('slug:')) return { kind: 'slug', slug: t.slice(5) }
  if (t.startsWith('/')) return { kind: 'file', filePath: t }
  return { kind: 'slug', slug: t }
}
```

### Diagnostic bundle (`fixtures/diagnostics.js` + `reporters/diagnostic-summary.js`)

Per test, the harness writes `tests/test-results/<slugified-test-name>/`:

| File | Contents |
|------|----------|
| `summary.json` | Test name, status, duration, target identification, video element final state (`currentTime`, `duration`, `paused`, `error`, `readyState`, `networkState`), HLS strategy from `/api/playback/start` response, hls.js fatal+non-fatal events, all `[Subtitle]`/`[Transcoder]` server log lines tailed during the test, count of `console.error` / `console.warn` lines, top 5 stderr lines, all checkpoint results |
| `console.browser.log` | All browser console messages, ISO-timestamped, with source file + line where available |
| `console.electron-main.log` | Electron main-process stdout/stderr — only present for the `electron` project |
| `network.har` | Every request: `/api/*`, HLS playlist + segments, `stream://*`. Bodies included for `/api/playback/start` and `.m3u8` files. Segment bodies stripped to headers + size to keep HARs small |
| `ffmpeg.server.log` | `Rails.logger` lines tagged `[Transcoder]` or `[Subtitle]` tailed during the test (between byte offsets recorded at test start/end) |
| `screenshots/start.png` | Just before `play()` |
| `screenshots/middle.png` | At the middle checkpoint |
| `screenshots/end.png` | At test end |
| `screenshots/failure.png` | On assertion failure (Playwright default behaviour) |
| `video.webm` | Playwright recording (already supported) |
| `trace.zip` | Playwright trace (already supported) |

Claude reads `summary.json` first; drills into the specific log only when the summary points there.

### Server log tailing (`fixtures/serverLog.js`)

```js
export const serverLogTail = async ({}, use) => {
  const logPath = path.resolve(__dirname, '../../server/log/development.log')
  const startOffset = fs.existsSync(logPath) ? fs.statSync(logPath).size : 0
  const start = () => startOffset
  const captureSince = () => { /* read [startOffset, currentSize), filter [Transcoder]/[Subtitle], write to ffmpeg.server.log */ }
  await use({ start, captureSince })
}
```

If `bin/desktop` is running and Rails was auto-started by Playwright, the file is created by Rails on first request. The probe-and-fallback server fixture handles both cases.

### Read-only enforcement

The client writes to several endpoints during normal playback:

| Endpoint | Side effect |
|---|---|
| `POST /api/playback/report_progress` (every ~10s during play) | `Episode#update_progress!`, `Movie#update_progress!`, `WatchHistory#update_progress!`, possibly `mark_watched!` |
| `POST /api/episodes/:id/play` | Creates `WatchHistory` record |
| `POST /api/episodes/:id/toggle` | Toggles `watched` flag |
| `POST /api/movies/:slug/play` | Creates `WatchHistory` record |
| `POST /api/movies/:slug/toggle` | Toggles `watched` flag |

Without protection, a single smoke run nudges watch history, creates spurious `WatchHistory` records, and may flip the `watched` flag on the played item. Solution: a shared `before_action` in `Api::BaseController`:

```ruby
class Api::BaseController < ApplicationController
  before_action :short_circuit_test_writes

  private

  def test_run?
    request.headers['X-Test-Run'] == '1'
  end

  def short_circuit_test_writes
    return unless test_run?
    return unless WRITE_ACTIONS_TO_STUB.include?([self.class.name, action_name])
    render json: { ok: true, testMode: true }
  end

  WRITE_ACTIONS_TO_STUB = [
    ['Api::PlaybackController', 'report_progress'],
    ['Api::EpisodesController', 'play'],
    ['Api::EpisodesController', 'toggle'],
    ['Api::MoviesController', 'play'],
    ['Api::MoviesController', 'toggle'],
  ].to_set.freeze
end
```

`POST /api/playback/start` and `seek` are NOT in the stub list — those create transient sessions, no DB writes that affect user data.

**HTTP adapter** — `ui/adapters/http.js` reads a flag from `localStorage` and adds the header to every fetch:

```js
function requestHeaders() {
  const headers = { 'Content-Type': 'application/json' }
  try {
    if (typeof localStorage !== 'undefined' && localStorage.getItem('__caramba_test_run__') === '1') {
      headers['X-Test-Run'] = '1'
    }
  } catch {}
  return headers
}
```

**Test harness** — `fixtures/base.js` calls `page.addInitScript(() => localStorage.setItem('__caramba_test_run__', '1'))` so every Playwright-controlled page sets the flag before any React code runs. The Electron renderer is the same — `addInitScript` works there too.

This is a 10-line change across two files. It can be reverted by clearing `localStorage` and the server header check. Production behaviour is unchanged because real users never set the flag.

### `assertPlayback(page, opts)` (`fixtures/asserts.js`)

```js
export async function assertPlayback(page, {
  checkpoints = [5_000, 15_000, 25_000],
  toleranceFraction = 0.1,
  seekProbe = true,
} = {}) {
  await page.waitForFunction(() => {
    const v = document.querySelector('video')
    return v && v.readyState >= 2
  }, { timeout: 15_000 })

  const t0 = await page.evaluate(() => document.querySelector('video').currentTime)
  const startedAt = Date.now()
  const results = []

  for (const ms of checkpoints) {
    const elapsed = Date.now() - startedAt
    if (elapsed < ms) await page.waitForTimeout(ms - elapsed)

    const sample = await page.evaluate(() => {
      const v = document.querySelector('video')
      return {
        currentTime: v.currentTime,
        paused: v.paused,
        readyState: v.readyState,
        error: v.error?.code ?? null,
        hlsErrors: window.__caramba_hls_errors__ || [],
      }
    })

    const expected = (ms / 1000) * (1 - toleranceFraction)
    const advanced = sample.currentTime - t0
    results.push({ checkpoint: ms, advanced, expected, sample })
    expect(advanced, `Stalled at checkpoint ${ms}ms (advanced ${advanced.toFixed(2)}s, expected ≥ ${expected.toFixed(2)}s)`).toBeGreaterThanOrEqual(expected)
    expect(sample.hlsErrors.filter(e => e.fatal), `Fatal hls.js errors at checkpoint ${ms}ms`).toEqual([])
  }

  if (!seekProbe) return { t0, checkpoints: results }

  // Mid-stream seek under load
  const seekTo = await page.evaluate(() => {
    const v = document.querySelector('video')
    return Math.min(v.currentTime + 60, v.duration > 0 ? v.duration / 2 : v.currentTime + 60)
  })
  await page.evaluate((t) => { document.querySelector('video').currentTime = t }, seekTo)
  await page.waitForTimeout(5_000)
  const afterSeek = await page.evaluate(() => document.querySelector('video').currentTime)
  expect(afterSeek, `Seek to ${seekTo} failed; player at ${afterSeek}`).toBeGreaterThan(seekTo)

  return { t0, checkpoints: results, seek: { to: seekTo, after: afterSeek } }
}
```

### `hls.js` event capture

`ui/components/VideoPlayer.jsx` already has an `Hls.Events.ERROR` handler that logs to console. Add (gated on `import.meta.env.DEV` OR presence of `localStorage.__caramba_test_run__`):

```js
hls.on(Hls.Events.ERROR, (_event, data) => {
  if (typeof window !== 'undefined') {
    window.__caramba_hls_errors__ = window.__caramba_hls_errors__ || []
    window.__caramba_hls_errors__.push({ fatal: data.fatal, type: data.type, details: data.details, ts: Date.now() })
  }
  // existing log + recovery code unchanged
})
```

`window.__caramba_hls__ = hls` is exposed under the same gate so `assertPlayback` can poke at the live instance for advanced diagnostics.

## Trigger model

`tests/package.json`:

```json
{
  "scripts": {
    "test": "playwright test",
    "test:web": "playwright test --project=web",
    "test:electron": "playwright test --project=electron",
    "test:smoke": "playwright test --grep @smoke",
    "test:playback": "playwright test --grep @playback"
  }
}
```

Root `package.json` adds:

```json
{
  "scripts": {
    "test:e2e": "pnpm --filter @caramba/tests test",
    "test:e2e:smoke": "pnpm --filter @caramba/tests test:smoke",
    "test:e2e:playback": "pnpm --filter @caramba/tests test:playback"
  }
}
```

`bin/test-playback`:

```bash
#!/usr/bin/env bash
# Usage: bin/test-playback <slug | path-to-file | episode:<id>>
exec env CARAMBA_TEST_TARGET="${1:-}" pnpm --filter @caramba/tests test:playback
```

Claude's typical invocations:

| Goal | Command |
|---|---|
| Smoke before declaring "done" | `pnpm test:e2e:smoke` |
| Reproduce a specific bug | `bin/test-playback /path/to/Dune.mkv` |
| Web only iteration | `pnpm --filter @caramba/tests test:web` |
| Electron only iteration | `pnpm --filter @caramba/tests test:electron` |
| Drill into one failing test | open `tests/test-results/<test-id>/summary.json` |

## Packages

| Workspace | Add (devDeps) |
|---|---|
| `tests/` (new) | `@playwright/test` (latest stable; brings `playwright` as transitive dep) |
| Root | none |

`pnpm-workspace.yaml`: add `tests` under `packages:`.

`.gitignore`: add `tests/test-results/`, `tests/playwright-report/`.

## File-by-file impact

**New**

- `tests/package.json`
- `tests/playwright.config.js`
- `tests/electron/launch.js`
- `tests/fixtures/base.js`, `library.js`, `diagnostics.js`, `server.js`, `serverLog.js`, `target.js`, `asserts.js`
- `tests/specs/web/smoke.shows.spec.js`, `smoke.movies.spec.js`, `playback.spec.js`
- `tests/specs/electron/smoke.launch.spec.js`, `smoke.playback.spec.js`, `playback.spec.js`
- `tests/reporters/diagnostic-summary.js`
- `bin/test-playback`

**Modified**

- `pnpm-workspace.yaml` — add `tests`
- `package.json` (root) — add `test:e2e*` scripts
- `.gitignore` — add `tests/test-results/`, `tests/playwright-report/`
- `server/app/controllers/api/base_controller.rb` — `before_action :short_circuit_test_writes` covering `report_progress` / episode `play|toggle` / movie `play|toggle` when `X-Test-Run: 1`
- `ui/adapters/http.js` — `requestHeaders()` helper that adds `X-Test-Run: 1` when `localStorage.__caramba_test_run__ === '1'`
- `ui/components/VideoPlayer.jsx` — push hls.js errors into `window.__caramba_hls_errors__` and expose `window.__caramba_hls__`, gated on dev / test flag
- `desktop/electron/db.js` — honour `process.env.CARAMBA_STORAGE_PATH` when set (dev path remains the fallback)
- `desktop/electron/services/api-config.js` — honour the same env var (it calls `db.getStoragePath()` so this falls out of the db.js change for free, but verify)

## Verification

A complete implementation is verified by, in order:

1. `pnpm install` succeeds, the new `tests` workspace links cleanly.
2. `cd tests && pnpm exec playwright install chromium` succeeds.
3. With Rails not running and no `bin/desktop` foreground: `pnpm test:e2e:smoke` auto-starts Rails on :3001, runs both `web` and `electron` smoke specs to green, tears down Rails on exit.
4. With `bin/desktop` already running: `pnpm test:e2e:smoke` reuses :3001 and :3000 / :5173, runs to green, the dev session is unaffected (no port conflict, no DB lock).
5. `tests/test-results/<one-test>/summary.json` exists with `status`, `target`, `video.finalState`, `hls.strategy`, `hls.errors`, `console.errorCount`, `checkpoints[]`.
6. `tests/test-results/<electron-test>/console.electron-main.log` is non-empty and contains `Transcoder:` lines.
7. Watch history is unchanged after a smoke run — confirm by selecting `Episode#progress_seconds` for the played item before and after; identical values.
8. `bin/test-playback /path/to/<known-good-file>.mkv` runs to completion with green checkpoints.
9. `bin/test-playback /path/to/<intentionally-broken-fixture-on-disk>.mkv` (e.g. by passing a non-existent path) fails with a structured error in `summary.json` (`{ phase: 'startPlayback', error: '...' }`) — not a Playwright stack trace.
10. Mid-stream seek assertion succeeds for a normal file — `summary.json` `seek.to` and `seek.after` both populated, `after > to`.
11. Forced regression: introduce a synthetic `throw new Error('test')` into `desktop/electron/services/transcoder.js` `start()` — the electron playback test fails, `console.electron-main.log` shows the throw, `summary.json.errors[0].source === 'electron-main'`.

## Risks / Open questions

- **`CARAMBA_STORAGE_PATH` ergonomics in production.** The env var must only override the dev path, not `app.getPath('userData')`. Implementation should branch on `app.isPackaged` to keep packaged builds untouchable from the env.
- **hls.js error capture in non-dev builds.** Gating on `import.meta.env.DEV` plus a localStorage flag means the test mode hooks live in the production renderer too. Acceptable — they're inert without the flag, and the hook adds <1KB. Alternative if this is uncomfortable: separate `vite build --mode test` that defines `__CARAMBA_TEST__: true`.
- **Vite dev-server boot for the web project.** The web project depends on Vite on :3000. The server fixture probes :3000 too; if missing, spawns it. This duplicates `bin/web`'s job; acceptable because Playwright's `webServer` config handles teardown more cleanly than re-using foreman.
- **HAR body for HLS segments.** Including bodies makes HARs huge (4K segments are 2–4 MB each over 30s ≈ 60 MB). Strip segment bodies to size+headers; keep `.m3u8` text bodies. Implementation will configure `recordHar` with a `urlFilter`.
- **First-window timing for Electron.** `app.firstWindow()` resolves before React mounts; tests that immediately read DOM may race. `assertPlayback` uses `waitForFunction` so it's robust, but smoke specs that look for "shows page rendered" must use `page.waitForSelector` rather than `page.locator` directly.
- **Concurrent runs.** If the user is using the desktop app in `bin/desktop` while tests run, both share Rails dev DB, Vite (:3000 / :5173), and the foreman log. Read-only enforcement covers Rails. The Electron under test has its own isolated `userData` (decision #9). Port conflicts: tests must reuse :3000 / :5173 if a Vite dev server is running, not race to bind. Implementation: probe each port, treat HTTP-200 as "reuse", treat ECONNREFUSED as "spawn ours". Two Electron processes (user's + test's) opening different `better-sqlite3` files don't collide; the test's renderer connects to Rails via hybrid mode anyway.
- **`@smoke` total runtime.** With 30s playback assertions, one full smoke run is ~3 minutes (~5 specs × 30s + page-nav overhead). Acceptable for "before a release"; possibly long for "after every save". A follow-up could add a `@quick` tag with a 10s assertion (no checkpoints, just liveness).
- **Reporter coupling.** The custom reporter is tightly coupled to the diagnostic fixture (it reads files the fixture wrote). Both should live under `tests/` and share one helper module to avoid drift.
