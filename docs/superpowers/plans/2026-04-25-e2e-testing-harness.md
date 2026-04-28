# E2E Testing Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Playwright-based E2E harness that lets Claude reproduce playback bugs and detect regressions on the user's real local Caramba library, without requiring manual reproduction or pasted logs.

**Architecture:** New `tests/` pnpm workspace with Playwright projects for `web` (Chromium) and `electron` (`_electron.launch()`) — both consuming the same Rails dev DB via runtime library discovery. Always-on diagnostic bundle (browser/Electron-main consoles, network HAR, server transcoder log, screenshots, summary.json) is written per test by a custom reporter. Tests carry an `X-Test-Run: 1` header, which the Rails API short-circuits on write endpoints so the user's watch history isn't mutated. Electron is launched with an isolated `userData` (temp dir per run) via a new `CARAMBA_STORAGE_PATH` env override.

**Tech Stack:** `@playwright/test`, `playwright` (Electron support), Node ≥ 18, plain JS, pnpm workspaces, Rails 8, hls.js (already in repo), `better-sqlite3` (already in repo).

**Spec:** [`docs/superpowers/specs/2026-04-25-e2e-testing-harness-design.md`](../specs/2026-04-25-e2e-testing-harness-design.md)

---

## Task 1: Workspace skeleton + Playwright install

**Files:**
- Create: `tests/package.json`
- Create: `tests/playwright.config.js`
- Modify: `pnpm-workspace.yaml`
- Modify: `package.json` (root)
- Modify: `.gitignore`

- [ ] **Step 1: Create `tests/package.json`**

```json
{
  "name": "@caramba/tests",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "test": "playwright test",
    "test:web": "playwright test --project=web",
    "test:electron": "playwright test --project=electron",
    "test:smoke": "playwright test --grep @smoke",
    "test:playback": "playwright test --grep @playback"
  },
  "devDependencies": {
    "@playwright/test": "^1.48.0"
  }
}
```

- [ ] **Step 2: Add `tests` to `pnpm-workspace.yaml` packages list**

Edit `pnpm-workspace.yaml`. Change:

```yaml
packages:
  - ui
  - desktop
  - web
  - android-tv
```

to:

```yaml
packages:
  - ui
  - desktop
  - web
  - android-tv
  - tests
```

(Leave the `allowBuilds` section untouched.)

- [ ] **Step 3: Add E2E scripts to root `package.json`**

In the root `package.json`, replace the `scripts` block:

```json
"scripts": {
  "test:ui": "pnpm --filter @caramba/ui test",
  "test:e2e": "pnpm --filter @caramba/tests test",
  "test:e2e:smoke": "pnpm --filter @caramba/tests test:smoke",
  "test:e2e:playback": "pnpm --filter @caramba/tests test:playback"
}
```

- [ ] **Step 4: Update `.gitignore`**

Append to `.gitignore`:

```
# Playwright
tests/test-results
tests/playwright-report
tests/.playwright
```

- [ ] **Step 5: Create initial `tests/playwright.config.js`**

```js
const path = require('path')
const { defineConfig, devices } = require('@playwright/test')

const ROOT = path.resolve(__dirname, '..')

module.exports = defineConfig({
  testDir: './specs',
  outputDir: './test-results',
  timeout: 90_000,
  fullyParallel: false,
  workers: 1,
  reporter: [
    ['list'],
    ['html', { outputFolder: './playwright-report', open: 'never' }],
  ],
  use: {
    trace: 'on',
    video: 'on',
    screenshot: 'only-on-failure',
    actionTimeout: 10_000,
    navigationTimeout: 20_000,
  },
  projects: [
    {
      name: 'web',
      testDir: './specs/web',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'http://localhost:3000',
      },
    },
    {
      name: 'electron',
      testDir: './specs/electron',
    },
  ],
})
```

- [ ] **Step 6: Install dependencies + Playwright browser**

Run:

```bash
pnpm install
cd tests && pnpm exec playwright install chromium
```

Expected: `pnpm install` completes without errors, `playwright install` downloads Chromium (≈ 150 MB).

- [ ] **Step 7: Commit**

```bash
git add tests/package.json tests/playwright.config.js pnpm-workspace.yaml package.json pnpm-lock.yaml .gitignore
git commit -m "tests: add @caramba/tests workspace + Playwright scaffold"
```

---

## Task 2: Server probe-and-fallback fixture + first passing spec

**Files:**
- Create: `tests/fixtures/server.js`
- Create: `tests/specs/web/_meta.spec.js`

- [ ] **Step 1: Write `tests/fixtures/server.js`**

```js
// Probe-and-fallback for the Rails dev server on :3001.
// If health check answers, reuse it (most common during dev). If not,
// spawn `bin/rails server -p 3001` from the server/ directory and wait for it.
const { spawn } = require('child_process')
const path = require('path')

const RAILS_PORT = 3001
const HEALTH_URL = `http://localhost:${RAILS_PORT}/api/health`

async function probeHealth(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(HEALTH_URL, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

async function waitForHealth(maxMs = 30_000) {
  const start = Date.now()
  while (Date.now() - start < maxMs) {
    if (await probeHealth()) return true
    await new Promise(r => setTimeout(r, 500))
  }
  return false
}

let spawnedProc = null

async function ensureRails() {
  if (await probeHealth()) return { spawned: false, apiBase: `http://localhost:${RAILS_PORT}` }

  const serverDir = path.resolve(__dirname, '..', '..', 'server')
  spawnedProc = spawn('bin/rails', ['server', '-p', String(RAILS_PORT), '-b', '0.0.0.0'], {
    cwd: serverDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, RAILS_ENV: 'development' },
    detached: false,
  })
  spawnedProc.stdout.on('data', () => {})
  spawnedProc.stderr.on('data', () => {})

  const ok = await waitForHealth()
  if (!ok) throw new Error('Rails did not become healthy on :3001 within 30s')
  return { spawned: true, apiBase: `http://localhost:${RAILS_PORT}` }
}

async function shutdown() {
  if (!spawnedProc) return
  spawnedProc.kill('SIGTERM')
  spawnedProc = null
}

module.exports = { ensureRails, shutdown, RAILS_PORT, HEALTH_URL }
```

- [ ] **Step 2: Write `tests/specs/web/_meta.spec.js`**

```js
const { test, expect } = require('@playwright/test')
const { ensureRails, shutdown } = require('../../fixtures/server')

test.beforeAll(async () => { await ensureRails() })
test.afterAll(async () => { await shutdown() })

test('@smoke rails health responds', async ({ request }) => {
  const res = await request.get('http://localhost:3001/api/health')
  expect(res.ok()).toBe(true)
})
```

- [ ] **Step 3: Run the test against an already-running Rails (reuse path)**

In one terminal:

```bash
cd server && bin/rails server -p 3001
```

In another:

```bash
cd tests && pnpm exec playwright test --project=web specs/web/_meta.spec.js
```

Expected: 1 passed; the spawned process is `null` (reused). Stop the manual Rails after.

- [ ] **Step 4: Run the test with no Rails running (auto-spawn path)**

Make sure no Rails is on :3001 (`lsof -i :3001` returns nothing). Run:

```bash
cd tests && pnpm exec playwright test --project=web specs/web/_meta.spec.js
```

Expected: 1 passed; took longer (Rails boot ~5-10s); `tests/test-results/` contains the trace.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/server.js tests/specs/web/_meta.spec.js
git commit -m "tests: add probe-and-fallback Rails server fixture + meta spec"
```

---

## Task 3: Server-side test-mode write protection (decision #8)

**Files:**
- Modify: `server/app/controllers/api/base_controller.rb`
- Test: `server/test/controllers/api/test_run_header_test.rb`

- [ ] **Step 1: Write the failing Minitest**

Create `server/test/controllers/api/test_run_header_test.rb`:

```ruby
require "test_helper"

class Api::TestRunHeaderTest < ActionDispatch::IntegrationTest
  setup do
    @episode = episodes(:bb_s01e01)
    @movie = movies(:the_matrix)
  end

  test "report_progress is short-circuited under X-Test-Run" do
    initial_progress = @episode.progress_seconds
    post "/api/playback/report_progress",
      params: { time: 999, duration: 1000, episode_id: @episode.id },
      headers: { "X-Test-Run" => "1" }
    assert_response :success
    assert_equal initial_progress, @episode.reload.progress_seconds
    body = JSON.parse(response.body)
    assert_equal true, body["testMode"]
  end

  test "episode play is short-circuited under X-Test-Run" do
    assert_no_difference -> { WatchHistory.count } do
      post "/api/episodes/#{@episode.id}/play", headers: { "X-Test-Run" => "1" }
    end
    assert_response :success
  end

  test "episode toggle is short-circuited under X-Test-Run" do
    initial = @episode.watched
    post "/api/episodes/#{@episode.id}/toggle", headers: { "X-Test-Run" => "1" }
    assert_equal initial, @episode.reload.watched
    assert_response :success
  end

  test "movie play is short-circuited under X-Test-Run" do
    assert_no_difference -> { WatchHistory.count } do
      post "/api/movies/#{@movie.slug}/play", headers: { "X-Test-Run" => "1" }
    end
    assert_response :success
  end

  test "movie toggle is short-circuited under X-Test-Run" do
    initial = @movie.watched
    post "/api/movies/#{@movie.slug}/toggle", headers: { "X-Test-Run" => "1" }
    assert_equal initial, @movie.reload.watched
    assert_response :success
  end

  test "report_progress writes normally without X-Test-Run" do
    post "/api/playback/report_progress",
      params: { time: 250, duration: 1000, episode_id: @episode.id }
    assert_response :success
    assert_equal 250, @episode.reload.progress_seconds
  end
end
```

- [ ] **Step 2: Run the test, confirm failure**

```bash
cd server && bin/rails test test/controllers/api/test_run_header_test.rb
```

Expected: 5 failures (under X-Test-Run, side effects still occur). The 6th (without header) should pass.

- [ ] **Step 3: Implement the short-circuit in `Api::BaseController`**

Replace `server/app/controllers/api/base_controller.rb` with:

```ruby
class Api::BaseController < ActionController::API
  include ActiveStorage::SetCurrent
  include Rails.application.routes.url_helpers

  STUBBED_TEST_ACTIONS = Set[
    "Api::PlaybackController#report_progress",
    "Api::EpisodesController#play",
    "Api::EpisodesController#toggle",
    "Api::MoviesController#play",
    "Api::MoviesController#toggle",
  ].freeze

  before_action :short_circuit_test_writes

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :unprocessable

  private

  def test_run?
    request.headers["X-Test-Run"] == "1"
  end

  def short_circuit_test_writes
    return unless test_run?
    key = "#{self.class.name}##{action_name}"
    return unless STUBBED_TEST_ACTIONS.include?(key)
    render json: { ok: true, testMode: true }
  end

  def not_found
    render json: { error: "Not found" }, status: :not_found
  end

  def unprocessable(exception)
    render json: { error: exception.record.errors.full_messages.join(", ") }, status: :unprocessable_entity
  end

  def poster_url_for(record)
    if record.respond_to?(:poster) && record.poster.attached?
      "#{request.base_url}#{rails_storage_proxy_path(record.poster)}"
    else
      record.try(:poster_url)
    end
  end
end
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
cd server && bin/rails test test/controllers/api/test_run_header_test.rb
```

Expected: all 6 tests pass.

- [ ] **Step 5: Run the full suite to make sure nothing else broke**

```bash
cd server && bin/rails test
```

Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add server/app/controllers/api/base_controller.rb server/test/controllers/api/test_run_header_test.rb
git commit -m "server: short-circuit write actions on X-Test-Run header"
```

---

## Task 4: Client-side test-mode header propagation

**Files:**
- Modify: `ui/adapters/http.js`
- Test: `ui/adapters/http.test.js`

- [ ] **Step 1: Write failing vitest**

Create `ui/adapters/http.test.js`:

```js
import { describe, test, expect, beforeEach, vi } from 'vitest'
import { createHttpAdapter } from './http'

describe('http adapter test-mode header', () => {
  beforeEach(() => {
    globalThis.localStorage = {
      _store: {},
      getItem(k) { return this._store[k] || null },
      setItem(k, v) { this._store[k] = v },
      removeItem(k) { delete this._store[k] },
    }
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: { get: () => 'application/json' },
      json: async () => ({ ok: true }),
    })
  })

  test('omits X-Test-Run header by default', async () => {
    const adapter = createHttpAdapter('http://localhost:3001')
    await adapter.listShows()
    const init = globalThis.fetch.mock.calls[0][1] || {}
    const headers = init.headers || {}
    expect(headers['X-Test-Run']).toBeUndefined()
  })

  test('sends X-Test-Run: 1 when localStorage flag set', async () => {
    globalThis.localStorage.setItem('__caramba_test_run__', '1')
    const adapter = createHttpAdapter('http://localhost:3001')
    await adapter.listShows()
    const init = globalThis.fetch.mock.calls[0][1] || {}
    const headers = init.headers || {}
    expect(headers['X-Test-Run']).toBe('1')
  })
})
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd ui && pnpm test
```

Expected: `http.test.js` fails (no header logic implemented yet); `scrubbers.test.js` still passes.

- [ ] **Step 3: Modify `ui/adapters/http.js` to inject the header**

In `ui/adapters/http.js`, add the helper near the top and use it in `request`:

Replace the function `request`:

```js
function buildHeaders(extra = {}) {
  const headers = { ...extra }
  try {
    if (typeof localStorage !== 'undefined' && localStorage.getItem('__caramba_test_run__') === '1') {
      headers['X-Test-Run'] = '1'
    }
  } catch {}
  return headers
}

async function request(path, opts = {}) {
  const url = `${base}${path}`
  const config = { ...opts }
  if (config.body && typeof config.body === 'object') {
    config.headers = buildHeaders({ 'Content-Type': 'application/json', ...config.headers })
    config.body = JSON.stringify(config.body)
  } else {
    config.headers = buildHeaders(config.headers)
  }
  const res = await fetch(url, config)
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`API ${res.status}: ${text}`)
  }
  const contentType = res.headers.get('content-type')
  if (contentType && contentType.includes('application/json')) {
    return res.json()
  }
  return null
}
```

(`buildHeaders` is defined inside `createHttpAdapter` so `base` and config stay scoped.)

- [ ] **Step 4: Run vitest, confirm pass**

```bash
cd ui && pnpm test
```

Expected: both `http.test.js` and `scrubbers.test.js` pass.

- [ ] **Step 5: Commit**

```bash
git add ui/adapters/http.js ui/adapters/http.test.js
git commit -m "ui: http adapter forwards X-Test-Run when localStorage flag set"
```

---

## Task 5: Library probes + first web smoke spec

**Files:**
- Create: `tests/fixtures/library.js`
- Create: `tests/fixtures/base.js`
- Create: `tests/specs/web/smoke.shows.spec.js`

- [ ] **Step 1: Write `tests/fixtures/library.js`**

```js
async function probeFirstShow(apiBase) {
  const res = await fetch(`${apiBase}/api/shows`)
  if (!res.ok) throw new Error(`GET /api/shows failed with ${res.status}`)
  const shows = await res.json()
  if (!shows.length) throw new Error('Library has no shows — add at least one to dev DB')
  return shows[0]
}

async function probeFirstMovie(apiBase) {
  const res = await fetch(`${apiBase}/api/movies`)
  if (!res.ok) throw new Error(`GET /api/movies failed with ${res.status}`)
  const movies = await res.json()
  if (!movies.length) throw new Error('Library has no movies — add at least one to dev DB')
  return movies[0]
}

async function probeFirstEpisode(apiBase) {
  const show = await probeFirstShow(apiBase)
  const res = await fetch(`${apiBase}/api/shows/${show.slug}/full`)
  if (!res.ok) throw new Error(`GET /api/shows/${show.slug}/full failed with ${res.status}`)
  const full = await res.json()
  for (const season of full.seasons || []) {
    const ep = (season.episodes || []).find(e => e.filePath)
    if (ep) return { ...ep, showSlug: show.slug }
  }
  throw new Error(`Show ${show.slug} has no episodes with file paths`)
}

module.exports = { probeFirstShow, probeFirstMovie, probeFirstEpisode }
```

- [ ] **Step 2: Write `tests/fixtures/base.js`**

```js
const { test: baseTest } = require('@playwright/test')
const { ensureRails } = require('./server')
const { probeFirstShow, probeFirstMovie, probeFirstEpisode } = require('./library')

const test = baseTest.extend({
  apiBase: async ({}, use) => {
    const { apiBase } = await ensureRails()
    await use(apiBase)
  },
  library: async ({ apiBase }, use) => {
    await use({
      firstShow: () => probeFirstShow(apiBase),
      firstMovie: () => probeFirstMovie(apiBase),
      firstEpisode: () => probeFirstEpisode(apiBase),
    })
  },
  page: async ({ page }, use) => {
    // Set the test-run flag before any app code runs
    await page.addInitScript(() => {
      try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
    })
    await use(page)
  },
})

module.exports = { test, expect: baseTest.expect }
```

- [ ] **Step 3: Write `tests/specs/web/smoke.shows.spec.js`**

```js
const { test, expect } = require('../../fixtures/base')

test('@smoke shows page renders and shows the first show', async ({ page, library }) => {
  const first = await library.firstShow()
  await page.goto('/')
  // Wait for the shows grid to populate
  const link = page.locator(`a[href="/shows/${first.slug}"]`).first()
  await expect(link).toBeVisible({ timeout: 15_000 })
})
```

- [ ] **Step 4: Run smoke spec**

Make sure web Vite is on :3000 (`cd web && pnpm dev` in another terminal) and Rails is on :3001 (or rely on auto-start). Then:

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.shows.spec.js
```

Expected: 1 passed. If your dev DB has no shows, the test fails with the descriptive error from `library.firstShow()`.

- [ ] **Step 5: Add web Vite probe to the server fixture**

Update `tests/fixtures/server.js`. Add at top alongside `RAILS_PORT`:

```js
const VITE_WEB_PORT = 3000
const VITE_HEALTH_URL = `http://localhost:${VITE_WEB_PORT}/`
```

Add a new `ensureViteWeb()` function modelled on `ensureRails`, but spawning `pnpm exec vite --port 3000 --host` from the `web/` directory. Track its child process separately and tear it down in `shutdown()`. Export it.

```js
const VITE_WEB_PORT = 3000

async function probeViteWeb(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(`http://localhost:${VITE_WEB_PORT}/`, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

let viteProc = null
async function ensureViteWeb() {
  if (await probeViteWeb()) return { spawned: false }
  const webDir = path.resolve(__dirname, '..', '..', 'web')
  viteProc = spawn('pnpm', ['exec', 'vite', '--port', String(VITE_WEB_PORT), '--host'], {
    cwd: webDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
    detached: false,
  })
  viteProc.stdout.on('data', () => {})
  viteProc.stderr.on('data', () => {})

  const start = Date.now()
  while (Date.now() - start < 30_000) {
    if (await probeViteWeb()) return { spawned: true }
    await new Promise(r => setTimeout(r, 500))
  }
  throw new Error('Vite web did not become healthy on :3000 within 30s')
}
```

Update `shutdown` to also kill `viteProc` (set it to null at end).

Update the exports to include `ensureViteWeb`.

- [ ] **Step 6: Plumb `ensureViteWeb` into the web project via global setup**

Create `tests/fixtures/global-setup.js`:

```js
const { ensureRails, ensureViteWeb } = require('./server')

module.exports = async (config) => {
  await ensureRails()
  // Web project depends on Vite; Electron project does not. The global setup
  // is run once per `playwright test` invocation, so we always start Vite.
  // (If only `--project=electron` is passed, we still start Vite — minor cost.)
  await ensureViteWeb()
}
```

Update `tests/playwright.config.js`:

```js
module.exports = defineConfig({
  globalSetup: require.resolve('./fixtures/global-setup.js'),
  globalTeardown: require.resolve('./fixtures/global-teardown.js'),
  // ... rest unchanged
})
```

Create `tests/fixtures/global-teardown.js`:

```js
const { shutdown } = require('./server')

module.exports = async () => {
  await shutdown()
}
```

Replace `tests/specs/web/_meta.spec.js`'s `beforeAll`/`afterAll` lifecycle with simple test (rely on global setup):

```js
const { test, expect } = require('@playwright/test')

test('@smoke rails health responds', async ({ request }) => {
  const res = await request.get('http://localhost:3001/api/health')
  expect(res.ok()).toBe(true)
})
```

- [ ] **Step 7: Run web smoke specs end-to-end**

```bash
cd tests && pnpm exec playwright test --project=web --grep @smoke
```

Expected: 2 passed (`_meta` and `smoke.shows`). Both Rails and Vite are auto-started/torn-down by global setup.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/library.js tests/fixtures/base.js tests/fixtures/global-setup.js tests/fixtures/global-teardown.js tests/fixtures/server.js tests/specs/web/smoke.shows.spec.js tests/specs/web/_meta.spec.js tests/playwright.config.js
git commit -m "tests: library probes + base fixture + web shows smoke"
```

---

## Task 6: Movies smoke + write-protection integration check

**Files:**
- Create: `tests/specs/web/smoke.movies.spec.js`
- Create: `tests/specs/web/_write_protection.spec.js`

- [ ] **Step 1: Write `tests/specs/web/smoke.movies.spec.js`**

```js
const { test, expect } = require('../../fixtures/base')

test('@smoke movies page renders and shows the first movie', async ({ page, library }) => {
  const first = await library.firstMovie()
  await page.goto('/movies')
  // PosterCard renders div[role="button"] with aria-label={item.title} for movies
  // (item.name for shows). See ui/components/PosterCard.jsx.
  const card = page.getByRole('button', { name: first.title }).first()
  await expect(card).toBeVisible({ timeout: 15_000 })
})
```

- [ ] **Step 2: Write `tests/specs/web/_write_protection.spec.js`**

This is a quick integration spec ensuring the localStorage flag is actually set inside the running app and that fetches carry the header.

```js
const { test, expect } = require('../../fixtures/base')

test('@smoke localStorage carries the test-run flag inside the app', async ({ page }) => {
  await page.goto('/')
  const flag = await page.evaluate(() => localStorage.getItem('__caramba_test_run__'))
  expect(flag).toBe('1')
})

test('@smoke /api/movies request carries X-Test-Run header from the app', async ({ page }) => {
  const headers = []
  page.on('request', (req) => {
    if (req.url().includes('/api/')) headers.push(req.headers())
  })
  await page.goto('/movies')
  await page.waitForLoadState('networkidle')
  expect(headers.length).toBeGreaterThan(0)
  expect(headers.some(h => h['x-test-run'] === '1')).toBe(true)
})
```

- [ ] **Step 3: Run, confirm pass**

```bash
cd tests && pnpm exec playwright test --project=web --grep @smoke
```

Expected: 4 passed. (`x-test-run` is lowercased by Chromium per HTTP/2 spec; that's fine.)

- [ ] **Step 4: Commit**

```bash
git add tests/specs/web/smoke.movies.spec.js tests/specs/web/_write_protection.spec.js
git commit -m "tests: movies smoke + write-protection header integration"
```

---

## Task 7: VideoPlayer hls hooks + assertPlayback (without seek)

**Files:**
- Modify: `ui/components/VideoPlayer.jsx`
- Create: `tests/fixtures/asserts.js`

- [ ] **Step 1: Add hls.js hooks in `ui/components/VideoPlayer.jsx`**

Locate the existing `Hls.Events.ERROR` handler around line 238. Add error capture and a global handle to the `hls` instance, gated on dev mode or test flag.

In the section where `hls = new Hls(...)` is created (around line 220-230), after creation, add:

```js
const isTestOrDev = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.DEV) ||
  (typeof localStorage !== 'undefined' && localStorage.getItem('__caramba_test_run__') === '1')
if (isTestOrDev && typeof window !== 'undefined') {
  window.__caramba_hls__ = hls
  window.__caramba_hls_errors__ = []
}
```

Then update the existing `hls.on(Hls.Events.ERROR, ...)` handler to also push to the global array:

```js
hls.on(Hls.Events.ERROR, (_event, data) => {
  if (typeof window !== 'undefined' && Array.isArray(window.__caramba_hls_errors__)) {
    window.__caramba_hls_errors__.push({
      fatal: !!data.fatal,
      type: data.type,
      details: data.details,
      ts: Date.now(),
    })
  }
  if (!data.fatal) {
    console.log('[Player] hls.js non-fatal:', data.type, data.details)
    return
  }
  console.warn('[Player] hls.js fatal:', data.type, data.details)
  // existing recovery switch (NETWORK_ERROR / MEDIA_ERROR cases) unchanged
})
```

(Keep the existing recovery-case `switch` body intact — only add the push and the unchanged log lines around it.)

- [ ] **Step 2: Write `tests/fixtures/asserts.js`**

```js
const { expect } = require('@playwright/test')

async function assertPlayback(page, {
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

    const expectedMs = ms * (1 - toleranceFraction)
    const expectedSec = expectedMs / 1000
    const advanced = sample.currentTime - t0
    results.push({ checkpointMs: ms, advancedSec: advanced, expectedSec, sample })
    expect(advanced, `Stalled at checkpoint ${ms}ms (advanced ${advanced.toFixed(2)}s, expected ≥ ${expectedSec.toFixed(2)}s)`).toBeGreaterThanOrEqual(expectedSec)
    const fatal = sample.hlsErrors.filter(e => e.fatal)
    expect(fatal, `Fatal hls.js errors at checkpoint ${ms}ms: ${JSON.stringify(fatal)}`).toEqual([])
  }

  if (!seekProbe) return { t0, checkpoints: results }

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

module.exports = { assertPlayback }
```

- [ ] **Step 3: Commit (interim — assertPlayback used in next task)**

```bash
git add ui/components/VideoPlayer.jsx tests/fixtures/asserts.js
git commit -m "tests/ui: hls.js error capture hook + assertPlayback helper"
```

---

## Task 8: Smoke playback spec (web)

**Files:**
- Create: `tests/specs/web/smoke.playback.spec.js`

- [ ] **Step 1: Write the spec**

```js
const { test, expect } = require('../../fixtures/base')
const { assertPlayback } = require('../../fixtures/asserts')

test('@smoke first movie plays for 30s with checkpoints + seek', async ({ page, library }) => {
  const movie = await library.firstMovie()
  await page.goto(`/movies/${movie.slug}`)

  const playButton = page.getByRole('button', { name: /play/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()

  const result = await assertPlayback(page)
  expect(result.checkpoints.length).toBe(3)
  expect(result.seek.after).toBeGreaterThan(result.seek.to)
})
```

- [ ] **Step 2: Run**

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.playback.spec.js
```

Expected: 1 passed (within ~40-50s including page-nav). If it fails:
- Stall: review trace in `tests/playwright-report/`
- Play button selector mismatch: check `MovieShow.jsx` for actual button text/role

- [ ] **Step 3: Commit**

```bash
git add tests/specs/web/smoke.playback.spec.js
git commit -m "tests: web smoke playback (30s + seek probe)"
```

---

## Task 9: Diagnostics fixture (browser console + video state collection)

**Files:**
- Create: `tests/fixtures/diagnostics.js`
- Modify: `tests/fixtures/base.js`

- [ ] **Step 1: Write `tests/fixtures/diagnostics.js`**

```js
const fs = require('fs')
const path = require('path')

function attachConsoleCapture(page) {
  const lines = []
  page.on('console', (msg) => {
    const loc = msg.location()
    lines.push({
      ts: new Date().toISOString(),
      type: msg.type(),
      text: msg.text(),
      url: loc.url || null,
      lineNumber: loc.lineNumber ?? null,
    })
  })
  page.on('pageerror', (err) => {
    lines.push({
      ts: new Date().toISOString(),
      type: 'pageerror',
      text: `${err.name}: ${err.message}\n${err.stack || ''}`,
    })
  })
  return {
    snapshot() { return lines.slice() },
    counts() {
      return {
        error: lines.filter(l => l.type === 'error' || l.type === 'pageerror').length,
        warning: lines.filter(l => l.type === 'warning' || l.type === 'warn').length,
        total: lines.length,
      }
    },
  }
}

async function captureVideoFinalState(page) {
  return page.evaluate(() => {
    const v = document.querySelector('video')
    if (!v) return null
    return {
      currentTime: v.currentTime,
      duration: Number.isFinite(v.duration) ? v.duration : null,
      paused: v.paused,
      readyState: v.readyState,
      networkState: v.networkState,
      errorCode: v.error?.code ?? null,
      hlsErrors: window.__caramba_hls_errors__ || [],
      hlsStrategy: window.__caramba_hls_strategy__ || null,
    }
  })
}

function writeBundleFile(testInfo, name, contents) {
  const dir = testInfo.outputDir
  fs.mkdirSync(dir, { recursive: true })
  const p = path.join(dir, name)
  fs.writeFileSync(p, typeof contents === 'string' ? contents : JSON.stringify(contents, null, 2))
  return p
}

module.exports = { attachConsoleCapture, captureVideoFinalState, writeBundleFile }
```

- [ ] **Step 2: Wire into `tests/fixtures/base.js`**

Replace `tests/fixtures/base.js` with:

```js
const { test: baseTest } = require('@playwright/test')
const { ensureRails } = require('./server')
const { probeFirstShow, probeFirstMovie, probeFirstEpisode } = require('./library')
const { attachConsoleCapture, captureVideoFinalState, writeBundleFile } = require('./diagnostics')

const test = baseTest.extend({
  apiBase: async ({}, use) => {
    const { apiBase } = await ensureRails()
    await use(apiBase)
  },
  library: async ({ apiBase }, use) => {
    await use({
      firstShow: () => probeFirstShow(apiBase),
      firstMovie: () => probeFirstMovie(apiBase),
      firstEpisode: () => probeFirstEpisode(apiBase),
    })
  },
  page: async ({ page }, use, testInfo) => {
    await page.addInitScript(() => {
      try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
    })
    const consoleCap = attachConsoleCapture(page)
    await use(page)
    // After test: write console log + video final state + summary stub
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}${l.url ? ` (${l.url}:${l.lineNumber ?? '?'})` : ''}`).join('\n'))
    let videoState = null
    try { videoState = await captureVideoFinalState(page) } catch {}
    const stub = {
      test: testInfo.title,
      project: testInfo.project.name,
      status: testInfo.status,
      duration: testInfo.duration,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
    }
    writeBundleFile(testInfo, 'summary.partial.json', stub)
  },
})

module.exports = { test, expect: baseTest.expect }
```

- [ ] **Step 3: Run smoke playback to verify diagnostic files appear**

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.playback.spec.js
```

Expected: 1 passed. After:

```bash
ls tests/test-results/specs-web-smoke-playback*/
```

Expected: `console.browser.log` and `summary.partial.json` present. `summary.partial.json` includes `video.currentTime` ≈ post-seek time, `console.error` count.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/diagnostics.js tests/fixtures/base.js
git commit -m "tests: diagnostic capture (console + video state) per test"
```

---

## Task 10: Server log tail fixture

**Files:**
- Create: `tests/fixtures/serverLog.js`
- Modify: `tests/fixtures/base.js`

- [ ] **Step 1: Write `tests/fixtures/serverLog.js`**

```js
const fs = require('fs')
const path = require('path')

const LOG_PATH = path.resolve(__dirname, '..', '..', 'server', 'log', 'development.log')
const FILTER = /\[(Transcoder|Subtitle)\]/

function startTail() {
  const offset = fs.existsSync(LOG_PATH) ? fs.statSync(LOG_PATH).size : 0
  return { logPath: LOG_PATH, startOffset: offset }
}

function captureSince({ logPath, startOffset }) {
  if (!fs.existsSync(logPath)) return ''
  const fd = fs.openSync(logPath, 'r')
  try {
    const stat = fs.fstatSync(fd)
    if (stat.size <= startOffset) return ''
    const length = stat.size - startOffset
    const buf = Buffer.alloc(Math.min(length, 8 * 1024 * 1024))  // cap at 8MB per test
    fs.readSync(fd, buf, 0, buf.length, startOffset)
    const text = buf.toString('utf8')
    return text.split('\n').filter(l => FILTER.test(l)).join('\n')
  } finally {
    fs.closeSync(fd)
  }
}

module.exports = { startTail, captureSince }
```

- [ ] **Step 2: Wire into `base.js`**

In `tests/fixtures/base.js`, add `serverLog` to the page fixture. Update the `page` fixture to:

```js
const { startTail, captureSince } = require('./serverLog')
// ... at top of base.js

  page: async ({ page }, use, testInfo) => {
    await page.addInitScript(() => {
      try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
    })
    const consoleCap = attachConsoleCapture(page)
    const tail = startTail()
    await use(page)
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}${l.url ? ` (${l.url}:${l.lineNumber ?? '?'})` : ''}`).join('\n'))
    writeBundleFile(testInfo, 'ffmpeg.server.log', captureSince(tail))
    let videoState = null
    try { videoState = await captureVideoFinalState(page) } catch {}
    const stub = {
      test: testInfo.title,
      project: testInfo.project.name,
      status: testInfo.status,
      duration: testInfo.duration,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
    }
    writeBundleFile(testInfo, 'summary.partial.json', stub)
  },
```

- [ ] **Step 3: Run smoke playback, verify ffmpeg log present**

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.playback.spec.js
ls tests/test-results/specs-web-smoke-playback*/
cat tests/test-results/specs-web-smoke-playback*/ffmpeg.server.log
```

Expected: file exists; contains lines like `[Transcoder] session ...: ..., starting at 0s, strategy=...`.

- [ ] **Step 4: Commit**

```bash
git add tests/fixtures/serverLog.js tests/fixtures/base.js
git commit -m "tests: tail server transcoder log into per-test bundle"
```

---

## Task 11: Custom diagnostic-summary reporter

**Files:**
- Create: `tests/reporters/diagnostic-summary.js`
- Modify: `tests/playwright.config.js`

- [ ] **Step 1: Write the reporter**

```js
const fs = require('fs')
const path = require('path')

class DiagnosticSummaryReporter {
  onTestEnd(test, result) {
    const dir = result.attachments.find(a => a.name === 'trace')?.path
      ? path.dirname(result.attachments.find(a => a.name === 'trace').path)
      : test.outputDir
    if (!dir) return

    const partialPath = path.join(dir, 'summary.partial.json')
    const partial = fs.existsSync(partialPath) ? JSON.parse(fs.readFileSync(partialPath, 'utf8')) : {}
    const ffmpegLogPath = path.join(dir, 'ffmpeg.server.log')
    const ffmpegLog = fs.existsSync(ffmpegLogPath) ? fs.readFileSync(ffmpegLogPath, 'utf8') : ''

    const errors = result.errors.map(e => ({
      message: e.message || String(e),
      stack: e.stack,
      location: e.location,
    }))

    const summary = {
      ...partial,
      status: result.status,
      duration: result.duration,
      retry: result.retry,
      errors,
      ffmpegLines: ffmpegLog.split('\n').filter(Boolean).slice(0, 500),
      attachments: result.attachments.map(a => ({ name: a.name, path: a.path, contentType: a.contentType })),
    }

    fs.writeFileSync(path.join(dir, 'summary.json'), JSON.stringify(summary, null, 2))
  }
}

module.exports = DiagnosticSummaryReporter
```

- [ ] **Step 2: Register the reporter**

Update `tests/playwright.config.js` `reporter` array:

```js
reporter: [
  ['list'],
  ['html', { outputFolder: './playwright-report', open: 'never' }],
  ['./reporters/diagnostic-summary.js'],
],
```

- [ ] **Step 3: Run smoke playback, verify summary.json**

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.playback.spec.js
cat tests/test-results/specs-web-smoke-playback*/summary.json
```

Expected: contains `status: "passed"`, `duration`, `video.currentTime`, `console.error` count, `ffmpegLines: [...]`, `attachments: [...]`.

- [ ] **Step 4: Commit**

```bash
git add tests/reporters/diagnostic-summary.js tests/playwright.config.js
git commit -m "tests: custom reporter writes summary.json per test"
```

---

## Task 12: Electron storage path env override

**Files:**
- Modify: `desktop/electron/db.js`
- Test: manual (no automated test for env-var indirection — smoke test in Task 13 covers it end-to-end)

- [ ] **Step 1: Modify `desktop/electron/db.js` `getStoragePath`**

Replace the `getStoragePath` function:

```js
function getStoragePath() {
  // Env override (test harness only). Ignored in packaged builds so the prod
  // app can never have its userData redirected via env.
  if (!app.isPackaged && process.env.CARAMBA_STORAGE_PATH) {
    fs.mkdirSync(process.env.CARAMBA_STORAGE_PATH, { recursive: true })
    return process.env.CARAMBA_STORAGE_PATH
  }
  if (app.isPackaged) {
    const p = path.join(app.getPath('userData'), 'storage')
    fs.mkdirSync(p, { recursive: true })
    return p
  }
  const p = path.join(__dirname, '..', 'storage')
  fs.mkdirSync(p, { recursive: true })
  return p
}
```

- [ ] **Step 2: Manually verify `api-config.js` already uses `db.getStoragePath()`**

Run:

```bash
grep -n 'getStoragePath\|storage' desktop/electron/services/api-config.js
```

Expected: `api-config.js` references `db.getStoragePath()` for `configPath()`. No code change needed there — it picks up the env override transparently.

- [ ] **Step 3: Verify no regression with normal dev run**

Stop any running Electron, then:

```bash
cd desktop && pnpm dev
# in another shell
cd desktop && pnpm exec electron .
```

Expected: Electron opens, finds the existing dev DB at `desktop/storage/development.sqlite3`, lists existing shows. Quit Electron.

- [ ] **Step 4: Verify env override works**

```bash
TEMP_STORAGE=$(mktemp -d)
cd desktop && CARAMBA_STORAGE_PATH="$TEMP_STORAGE" pnpm exec electron .
```

Expected: Electron opens with an empty library (new DB at `$TEMP_STORAGE/development.sqlite3`). Quit Electron and `rm -rf "$TEMP_STORAGE"`.

- [ ] **Step 5: Commit**

```bash
git add desktop/electron/db.js
git commit -m "desktop: CARAMBA_STORAGE_PATH overrides dev storage dir (test harness)"
```

---

## Task 13: Electron launch fixture + electron smoke launch spec

**Files:**
- Create: `tests/electron/launch.js`
- Create: `tests/specs/electron/smoke.launch.spec.js`

- [ ] **Step 1: Write `tests/electron/launch.js`**

```js
const fs = require('fs')
const os = require('os')
const path = require('path')
const { _electron: electron } = require('playwright')

const DESKTOP_DIR = path.resolve(__dirname, '..', '..', 'desktop')

async function launchHybrid({ apiBase = 'http://localhost:3001', viteDevUrl = 'http://localhost:5173' } = {}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'caramba-test-'))
  const storageDir = path.join(tempDir, 'storage')
  fs.mkdirSync(storageDir, { recursive: true })
  fs.writeFileSync(
    path.join(storageDir, 'api_config.json'),
    JSON.stringify({ enabled: true, server_url: apiBase, local_playback: true }, null, 2),
  )

  const mainLog = []
  const app = await electron.launch({
    args: ['./electron/main.js'],
    cwd: DESKTOP_DIR,
    env: {
      ...process.env,
      CARAMBA_STORAGE_PATH: storageDir,
      VITE_DEV_URL: viteDevUrl,
      ELECTRON_DISABLE_SECURITY_WARNINGS: '1',
    },
    timeout: 30_000,
  })
  app.on('console', (msg) => {
    mainLog.push({ ts: new Date().toISOString(), type: msg.type(), text: msg.text() })
  })
  app.process().stdout?.on('data', (d) => mainLog.push({ ts: new Date().toISOString(), type: 'stdout', text: d.toString() }))
  app.process().stderr?.on('data', (d) => mainLog.push({ ts: new Date().toISOString(), type: 'stderr', text: d.toString() }))

  const window = await app.firstWindow({ timeout: 30_000 })
  await window.addInitScript(() => {
    try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
  })
  return {
    app,
    window,
    tempDir,
    mainLog,
    async close() {
      try { await app.close() } catch {}
      try { fs.rmSync(tempDir, { recursive: true, force: true }) } catch {}
    },
  }
}

module.exports = { launchHybrid }
```

- [ ] **Step 2: Make sure desktop Vite is running for renderer hot-load**

The Electron main process loads from `VITE_DEV_URL=http://localhost:5173` in dev. We need that running. Add a probe-and-spawn for desktop Vite to `tests/fixtures/server.js`:

```js
const VITE_DESKTOP_PORT = 5173

async function probeViteDesktop(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(`http://localhost:${VITE_DESKTOP_PORT}/`, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

let viteDesktopProc = null
async function ensureViteDesktop() {
  if (await probeViteDesktop()) return { spawned: false }
  const desktopDir = path.resolve(__dirname, '..', '..', 'desktop')
  viteDesktopProc = spawn('pnpm', ['exec', 'vite', '--port', String(VITE_DESKTOP_PORT)], {
    cwd: desktopDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
    detached: false,
  })
  viteDesktopProc.stdout.on('data', () => {})
  viteDesktopProc.stderr.on('data', () => {})

  const start = Date.now()
  while (Date.now() - start < 30_000) {
    if (await probeViteDesktop()) return { spawned: true }
    await new Promise(r => setTimeout(r, 500))
  }
  throw new Error('Vite desktop did not become healthy on :5173 within 30s')
}
```

Update `shutdown` to also kill `viteDesktopProc`. Export `ensureViteDesktop`.

Update `tests/fixtures/global-setup.js`:

```js
const { ensureRails, ensureViteWeb, ensureViteDesktop } = require('./server')

module.exports = async () => {
  await ensureRails()
  await ensureViteWeb()
  await ensureViteDesktop()
}
```

- [ ] **Step 3: Write `tests/specs/electron/smoke.launch.spec.js`**

```js
const { test: baseTest } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { probeFirstMovie } = require('../../fixtures/library')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid()
    await use(ctx)
    await ctx.close()
  },
})

test('@smoke electron launches in hybrid mode and renders shows page', async ({ electron }) => {
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  // Wait for at least one show poster to appear (proves hybrid mode is live)
  await window.waitForSelector('a[href^="#/shows/"], a[href^="/shows/"]', { timeout: 30_000 })
})
```

(The selector tolerates HashRouter (`#/shows/`) — Electron renderer uses `HashRouter` per CLAUDE.md.)

- [ ] **Step 4: Run electron smoke**

```bash
cd tests && pnpm exec playwright test --project=electron specs/electron/smoke.launch.spec.js
```

Expected: 1 passed. The Electron window appears briefly, navigates to the shows list, the test verifies a shows link exists, then closes.

- [ ] **Step 5: Commit**

```bash
git add tests/electron/launch.js tests/specs/electron/smoke.launch.spec.js tests/fixtures/server.js tests/fixtures/global-setup.js
git commit -m "tests: electron launch fixture + smoke launch spec (hybrid mode)"
```

---

## Task 14: Electron smoke playback spec + main-process console capture

**Files:**
- Create: `tests/specs/electron/smoke.playback.spec.js`
- Modify: `tests/fixtures/diagnostics.js`
- Modify: `tests/electron/launch.js` (export `mainLog` for diagnostics)

- [ ] **Step 1: Add `writeMainLog` helper to `tests/fixtures/diagnostics.js`**

Append to `diagnostics.js`:

```js
function formatMainLog(lines) {
  return lines.map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n')
}

module.exports = {
  attachConsoleCapture,
  captureVideoFinalState,
  writeBundleFile,
  formatMainLog,
}
```

- [ ] **Step 2: Write `tests/specs/electron/smoke.playback.spec.js`**

```js
const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { probeFirstMovie } = require('../../fixtures/library')
const { assertPlayback } = require('../../fixtures/asserts')
const { writeBundleFile, formatMainLog, attachConsoleCapture, captureVideoFinalState } = require('../../fixtures/diagnostics')
const { startTail, captureSince } = require('../../fixtures/serverLog')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid()
    const consoleCap = attachConsoleCapture(ctx.window)
    const tail = startTail()
    await use(ctx)
    writeBundleFile(testInfo, 'console.electron-main.log', formatMainLog(ctx.mainLog))
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n'))
    writeBundleFile(testInfo, 'ffmpeg.server.log', captureSince(tail))
    let videoState = null
    try { videoState = await captureVideoFinalState(ctx.window) } catch {}
    writeBundleFile(testInfo, 'summary.partial.json', {
      test: testInfo.title,
      project: testInfo.project.name,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
      mainLogLines: ctx.mainLog.length,
    })
    await ctx.close()
  },
})

async function navigateHash(window, hashRoute) {
  // Electron renderer uses HashRouter — change location.hash rather than goto().
  await window.evaluate((h) => { window.location.hash = h }, hashRoute)
}

test('@smoke electron plays first movie for 30s + seek probe', async ({ electron }) => {
  const movie = await probeFirstMovie('http://localhost:3001')
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  await navigateHash(window, `/movies/${movie.slug}`)
  const playButton = window.getByRole('button', { name: /play/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()
  const result = await assertPlayback(window)
  expect(result.checkpoints.length).toBe(3)
  expect(result.seek.after).toBeGreaterThan(result.seek.to)
})
```

(Note: Electron renderer uses `HashRouter`, so navigation is `#/movies/:slug`. `window.goto()` is fine because the BrowserWindow is loaded from a URL — Playwright treats it as a `Page`.)

- [ ] **Step 3: Run electron playback**

```bash
cd tests && pnpm exec playwright test --project=electron specs/electron/smoke.playback.spec.js
ls tests/test-results/specs-electron-smoke-playback*/
cat tests/test-results/specs-electron-smoke-playback*/console.electron-main.log
```

Expected: 1 passed; `console.electron-main.log` contains `Transcoder:` lines from `desktop/electron/services/transcoder.js`.

- [ ] **Step 4: Commit**

```bash
git add tests/specs/electron/smoke.playback.spec.js tests/fixtures/diagnostics.js
git commit -m "tests: electron smoke playback + main-process console capture"
```

---

## Task 15: Target resolver + parameterized playback specs

**Files:**
- Create: `tests/fixtures/target.js`
- Create: `tests/specs/web/playback.spec.js`
- Create: `tests/specs/electron/playback.spec.js`
- Test: `tests/fixtures/target.test.js`

- [ ] **Step 1: Write `tests/fixtures/target.test.js`**

```js
const { test, expect } = require('@playwright/test')
const { resolveTarget } = require('./target')

test('resolveTarget — empty env returns auto', () => {
  expect(resolveTarget(undefined)).toEqual({ kind: 'auto' })
  expect(resolveTarget('')).toEqual({ kind: 'auto' })
})

test('resolveTarget — file: prefix', () => {
  expect(resolveTarget('file:/tmp/foo.mkv')).toEqual({ kind: 'file', filePath: '/tmp/foo.mkv' })
})

test('resolveTarget — episode: prefix', () => {
  expect(resolveTarget('episode:42')).toEqual({ kind: 'episode', id: '42' })
})

test('resolveTarget — slug: prefix', () => {
  expect(resolveTarget('slug:dune-2021')).toEqual({ kind: 'slug', slug: 'dune-2021' })
})

test('resolveTarget — bare absolute path → file', () => {
  expect(resolveTarget('/Users/x/Movies/Dune.mkv')).toEqual({ kind: 'file', filePath: '/Users/x/Movies/Dune.mkv' })
})

test('resolveTarget — bare slug', () => {
  expect(resolveTarget('inception')).toEqual({ kind: 'slug', slug: 'inception' })
})
```

- [ ] **Step 2: Run, confirm failure**

```bash
cd tests && pnpm exec playwright test fixtures/target.test.js
```

Expected: failure ("Cannot find module './target'").

- [ ] **Step 3: Write `tests/fixtures/target.js`**

```js
function resolveTarget(envValue) {
  const t = envValue || ''
  if (!t) return { kind: 'auto' }
  if (t.startsWith('file:')) return { kind: 'file', filePath: t.slice(5) }
  if (t.startsWith('episode:')) return { kind: 'episode', id: t.slice(8) }
  if (t.startsWith('slug:')) return { kind: 'slug', slug: t.slice(5) }
  if (t.startsWith('/')) return { kind: 'file', filePath: t }
  return { kind: 'slug', slug: t }
}

module.exports = { resolveTarget }
```

- [ ] **Step 4: Run, confirm pass**

```bash
cd tests && pnpm exec playwright test fixtures/target.test.js
```

Expected: 6 passed.

- [ ] **Step 5: Write `tests/specs/web/playback.spec.js`**

```js
const { test, expect } = require('../../fixtures/base')
const { resolveTarget } = require('../../fixtures/target')
const { assertPlayback } = require('../../fixtures/asserts')

test('@playback parameterized playback (web)', async ({ page, library, apiBase }, testInfo) => {
  const target = resolveTarget(process.env.CARAMBA_TEST_TARGET)
  testInfo.annotations.push({ type: 'target', description: JSON.stringify(target) })

  let slug
  if (target.kind === 'auto') {
    const m = await library.firstMovie()
    slug = m.slug
  } else if (target.kind === 'slug') {
    slug = target.slug
  } else if (target.kind === 'file') {
    test.skip(true, 'file: targets are exercised via the electron project')
    return
  } else if (target.kind === 'episode') {
    test.skip(true, 'episode: targets are out of scope for v1 (use slug: or file:)')
    return
  }

  await page.goto(`/movies/${slug}`)
  const playButton = page.getByRole('button', { name: /play/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()
  const result = await assertPlayback(page, { seekProbe: true })
  expect(result.checkpoints.length).toBe(3)
})
```

- [ ] **Step 6: Write `tests/specs/electron/playback.spec.js`**

Same pattern as the electron smoke playback spec, with target resolution. Mirror `smoke.playback.spec.js` but:

- Tag as `@playback`
- Resolve target via `resolveTarget(process.env.CARAMBA_TEST_TARGET)`
- For `kind: 'file'`: invoke `window.api.startLocalPlayback(filePath)` via `page.evaluate` if such an IPC exists; else navigate via library lookup. Implementation detail: if the local adapter exposes a way to play any file on disk, use it; otherwise treat `file:` as "find a movie whose `filePath === target.filePath`" by querying `/api/movies` and matching.

```js
const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { resolveTarget } = require('../../fixtures/target')
const { probeFirstMovie } = require('../../fixtures/library')
const { assertPlayback } = require('../../fixtures/asserts')
const { writeBundleFile, formatMainLog, attachConsoleCapture, captureVideoFinalState } = require('../../fixtures/diagnostics')
const { startTail, captureSince } = require('../../fixtures/serverLog')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid()
    const consoleCap = attachConsoleCapture(ctx.window)
    const tail = startTail()
    await use(ctx)
    writeBundleFile(testInfo, 'console.electron-main.log', formatMainLog(ctx.mainLog))
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n'))
    writeBundleFile(testInfo, 'ffmpeg.server.log', captureSince(tail))
    let videoState = null
    try { videoState = await captureVideoFinalState(ctx.window) } catch {}
    writeBundleFile(testInfo, 'summary.partial.json', {
      test: testInfo.title,
      project: testInfo.project.name,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
    })
    await ctx.close()
  },
})

test('@playback parameterized playback (electron)', async ({ electron }, testInfo) => {
  const target = resolveTarget(process.env.CARAMBA_TEST_TARGET)
  testInfo.annotations.push({ type: 'target', description: JSON.stringify(target) })
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  const apiBase = 'http://localhost:3001'

  let nav
  if (target.kind === 'auto') {
    const m = await probeFirstMovie(apiBase)
    nav = `#/movies/${m.slug}`
  } else if (target.kind === 'slug') {
    nav = `#/movies/${target.slug}`
  } else if (target.kind === 'file') {
    const res = await fetch(`${apiBase}/api/movies`)
    const movies = await res.json()
    const m = movies.find(mm => mm.filePath === target.filePath)
    if (!m) {
      writeBundleFile(testInfo, 'summary.partial.json', { phase: 'resolveTarget', error: `No movie with filePath ${target.filePath}`, target })
      throw new Error(`No movie in library with filePath ${target.filePath}`)
    }
    nav = `#/movies/${m.slug}`
  } else if (target.kind === 'episode') {
    test.skip(true, 'episode: targets are out of scope for v1 (use slug: or file:)')
    return
  }

  await window.evaluate((h) => { window.location.hash = h }, nav.replace(/^#/, ''))
  const playButton = window.getByRole('button', { name: /play/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()
  const result = await assertPlayback(window, { seekProbe: true })
  expect(result.checkpoints.length).toBe(3)
})
```

- [ ] **Step 7: Run @playback grep with no env (uses first movie)**

```bash
cd tests && pnpm exec playwright test --grep @playback
```

Expected: 2 passed (web + electron).

- [ ] **Step 8: Run @playback with explicit slug target**

Pick one slug from your library (e.g. via `curl -s http://localhost:3001/api/movies | head -c 500`). Run:

```bash
cd tests && CARAMBA_TEST_TARGET=slug:<your-movie-slug> pnpm exec playwright test --grep @playback
```

Expected: 2 passed; `summary.json` `target` contains the resolved slug.

- [ ] **Step 9: Commit**

```bash
git add tests/fixtures/target.js tests/fixtures/target.test.js tests/specs/web/playback.spec.js tests/specs/electron/playback.spec.js
git commit -m "tests: target resolver + parameterized @playback specs"
```

---

## Task 16: bin/test-playback wrapper + HAR capture

**Files:**
- Create: `bin/test-playback`
- Modify: `tests/playwright.config.js`
- Modify: `tests/fixtures/base.js`

- [ ] **Step 1: Create `bin/test-playback`**

```bash
#!/usr/bin/env bash
# bin/test-playback <slug | path-to-file | episode:<id> | slug:<slug>>
# Reproduces a playback issue end-to-end: runs the @playback Playwright tests
# (web + electron) against the given target, writes a per-test diagnostic
# bundle to tests/test-results/.

set -euo pipefail

cd "$(dirname "$0")/.."

if [ -z "${1:-}" ]; then
  echo "Usage: bin/test-playback <slug | /abs/path.mkv | episode:<id> | slug:<slug> | file:<path>>" >&2
  exit 1
fi

exec env CARAMBA_TEST_TARGET="$1" pnpm --filter @caramba/tests test:playback
```

Make it executable:

```bash
chmod +x bin/test-playback
```

- [ ] **Step 2: Add HAR capture to web tests**

In `tests/playwright.config.js`, modify the `web` project's `use`:

```js
{
  name: 'web',
  testDir: './specs/web',
  use: {
    ...devices['Desktop Chrome'],
    baseURL: 'http://localhost:3000',
    recordHar: {
      mode: 'minimal', // strip large bodies; URLs + timings + headers retained
      content: 'omit',
    },
  },
},
```

(Electron HAR capture is more involved — Playwright's `_electron.launch()` doesn't accept `recordHar` directly. Skip Electron HAR for this iteration; the network requests it makes are visible in the trace.)

- [ ] **Step 3: Run, verify HAR present**

```bash
cd tests && pnpm exec playwright test --project=web specs/web/smoke.playback.spec.js
ls tests/test-results/specs-web-smoke-playback*/
```

Expected: a `*.har` file (or similar) appears in the test-results directory.

- [ ] **Step 4: Verify bin/test-playback round trip**

```bash
bin/test-playback slug:<your-movie-slug>
```

Expected: smoke and playback specs run; exit code 0; `tests/test-results/specs-electron-playback*/summary.json` has `target` set to the slug.

- [ ] **Step 5: Verify failure mode for invalid target**

```bash
bin/test-playback file:/nonexistent/path.mkv
```

Expected: exit non-zero; `tests/test-results/specs-electron-playback*/summary.partial.json` has `phase: 'resolveTarget'` and an error message; `summary.json` (final) has `status: failed` and `errors[0].message` describing the missing file.

- [ ] **Step 6: Commit**

```bash
git add bin/test-playback tests/playwright.config.js
git commit -m "tests: bin/test-playback wrapper + web HAR capture"
```

---

## Task 17: End-to-end verification

**Files:**
- Modify: `tests/specs/web/_meta.spec.js` (extend with watch-history-unchanged check)

- [ ] **Step 1: Write watch-history-unchanged assertion**

Append to `tests/specs/web/_write_protection.spec.js`:

```js
test('@smoke playback does not mutate Movie#progress_seconds', async ({ page, library, apiBase }) => {
  const movie = await library.firstMovie()

  const beforeRes = await fetch(`${apiBase}/api/movies/${movie.slug}`)
  const before = await beforeRes.json()
  const beforeProgress = before.progress_seconds ?? null

  await page.goto(`/movies/${movie.slug}`)
  const playButton = page.getByRole('button', { name: /play/i }).first()
  await playButton.click()
  await page.waitForFunction(() => {
    const v = document.querySelector('video')
    return v && v.currentTime > 5
  }, { timeout: 30_000 })
  // Long enough for at least one report_progress fire (~10s interval in player)
  await page.waitForTimeout(15_000)

  const afterRes = await fetch(`${apiBase}/api/movies/${movie.slug}`)
  const after = await afterRes.json()
  const afterProgress = after.progress_seconds ?? null

  expect(afterProgress).toBe(beforeProgress)
})
```

The `GET /api/movies/:slug` endpoint returns `progress_seconds` from `movie.as_json` (snake_case here even though most JSON shaped explicitly is camelCase — `as_json` defers to ActiveRecord). If the field shape changes, adjust accordingly.

- [ ] **Step 2: Run the full smoke set**

```bash
cd tests && pnpm exec playwright test --grep @smoke
```

Expected: all green. ~5 minutes total (web smoke + electron smoke + write-protection check).

- [ ] **Step 3: Run synthetic regression to confirm error capture**

Add a permanent test-only injection point at the top of `start()` in `desktop/electron/services/transcoder.js` (gated on env so production is unaffected):

```js
async function start(filePath, seekTime = 0, opts = {}) {
  if (process.env.CARAMBA_TEST_INJECT_FAIL === '1') {
    throw new Error('synthetic-test-failure')
  }
  // ... rest unchanged
}
```

The injection point stays in the codebase — it's three lines and useful for verifying the diagnostic bundle whenever it changes shape. Then run:

```bash
cd tests && CARAMBA_TEST_INJECT_FAIL=1 pnpm exec playwright test --project=electron specs/electron/smoke.playback.spec.js
```

Expected: failure; `tests/test-results/specs-electron-smoke-playback*/console.electron-main.log` contains `synthetic-test-failure`; `summary.json` `errors[0].message` references the failure.

Run again WITHOUT the env var to confirm normal operation:

```bash
cd tests && pnpm exec playwright test --project=electron specs/electron/smoke.playback.spec.js
```

Expected: pass.

- [ ] **Step 4: Verify summary.json schema is stable**

Pick any successful test result and inspect:

```bash
cat tests/test-results/specs-web-smoke-playback*/summary.json | jq 'keys'
```

Expected output (sorted keys):

```
[
  "attachments",
  "console",
  "duration",
  "errors",
  "ffmpegLines",
  "project",
  "retry",
  "status",
  "target",
  "test",
  "video"
]
```

If a key is missing or extra, fix the reporter / base fixture to converge.

- [ ] **Step 5: Run smoke against fresh shells (no dev servers running)**

Stop any `bin/desktop` / `bin/web` / `bin/rails` you have. Then:

```bash
pnpm test:e2e:smoke
```

Expected: auto-starts Rails on :3001, Vite on :3000, Vite on :5173; runs smoke; exits cleanly. `lsof -i :3001 :3000 :5173` shows no leftovers.

- [ ] **Step 6: Run smoke alongside an active `bin/desktop`**

In one terminal: `bin/desktop`. In another: `pnpm test:e2e:smoke`.

Expected: tests reuse the running servers; pass; the user's app session is unaffected (still navigating, still playing, no API errors).

- [ ] **Step 7: Final commit**

```bash
git add tests/specs/web/_write_protection.spec.js
git commit -m "tests: watch-history-unchanged smoke + verification harness complete"
```

---

## Self-review checklist (run BEFORE handing off)

- **Spec coverage:** every decision in the spec maps to at least one task above (sanity-check by skimming the spec's Decisions table against tasks 1–17).
- **No placeholders:** no "TBD", "TODO", or empty stubs in any task body.
- **Type consistency:** `assertPlayback` returns `{ t0, checkpoints[], seek }` everywhere it's called; `library.firstMovie/Show/Episode()` are async; `resolveTarget(env)` returns `{ kind, slug?, filePath?, id? }`.
- **Verification covered:** every spec verification step is exercised by at least one task's "Run" step.

## Out-of-scope / known follow-ups

- `@quick` tag with a 10s liveness assertion for tight inner loops.
- Electron HAR capture (would need a custom Playwright route handler since `_electron.launch()` doesn't accept `recordHar`).
- `episode:<id>` target support — currently `resolveTarget` parses the prefix but both web and electron specs `test.skip` it. Adding it requires looking up the episode's show, navigating there, and clicking the right row.
- CI integration — depends on CI having access to a populated dev DB; deferred per spec.
