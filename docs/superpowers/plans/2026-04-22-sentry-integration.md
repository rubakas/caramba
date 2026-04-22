# Sentry Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Sentry error + performance telemetry into `@caramba/web`, `@caramba/desktop` (renderer + Electron main), and `@caramba/android`, reporting to three pre-created Sentry projects, with aggressive PII scrubbing and source maps uploaded at build time.

**Architecture:** Shared SDK-agnostic facade in `ui/sentry/` (takes a Sentry object as a parameter so it works for `@sentry/react`, `@sentry/electron/renderer`, and `@sentry/capacitor` alike). Each client's entry calls `sentryInit({ Sentry, dsn, platform, release })`. Electron main is its own init. Release is derived from the bumped root `package.json` version and pushed into every build via `SENTRY_RELEASE` env var; `@sentry/vite-plugin` uploads source maps and deletes them from `dist/`.

**Tech Stack:** `@sentry/react`, `@sentry/electron`, `@sentry/capacitor`, `@sentry/vite-plugin`, vitest (new JS test runner for `ui/`), pnpm workspaces, Vite 6, Electron 33, Capacitor 6.

**Reference:** See `docs/superpowers/specs/2026-04-22-sentry-integration-design.md` for the full design, PII scrubbing rules, and the `platform` tag convention (`web`, `desktop-renderer`, `desktop-main`, `android-tv`).

---

## Task 1: Fix .gitignore so per-client .env files can be committed

**Files:**
- Modify: `.gitignore`

**Why:** Current `.gitignore` has `.env*` which blocks every `.env` file. Spec says DSNs are public and should be committed per client, so we restrict the ignore to `.local`-suffixed files only (Vite's standard for secrets).

- [ ] **Step 1: Read current gitignore**

Run: `cat .gitignore`

Expected: includes the line `.env*` under a "# Env" heading.

- [ ] **Step 2: Replace the env block**

In `.gitignore`, replace:

```
# Env
.env*
```

with:

```
# Env (Vite convention: *.local files hold secrets, never checked in)
.env.local
*.env.local
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "Restrict env ignore to *.local so per-client DSN .env files can be committed"
```

---

## Task 2: Set up vitest in ui/ and the root test script

**Files:**
- Modify: `ui/package.json`
- Modify: `package.json` (root)

**Why:** The repo has no JS test suite. Scrubbers are pure and critical for privacy — they deserve tests. Vitest is the zero-config choice for a Vite-based monorepo.

- [ ] **Step 1: Add vitest to `ui/` devDependencies**

Modify `ui/package.json` to add a `devDependencies` block and a `scripts` block:

```json
{
  "name": "@caramba/ui",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "peerDependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "react-router-dom": "^7.0.0"
  },
  "dependencies": {
    "@hashintel/refractive": "^0.0.3",
    "hls.js": "^1.6.15"
  },
  "devDependencies": {
    "vitest": "^2.1.0"
  }
}
```

- [ ] **Step 2: Add root test script**

Modify root `package.json`:

```json
{
  "private": true,
  "version": "v1.3.6",
  "description": "Caramba — media center monorepo",
  "scripts": {
    "test:ui": "pnpm --filter @caramba/ui test"
  },
  "pnpm": {
    "onlyBuiltDependencies": [
      "better-sqlite3",
      "electron",
      "esbuild"
    ]
  }
}
```

(Version string is whatever the root currently shows — do not modify it.)

- [ ] **Step 3: Install**

Run: `pnpm install`
Expected: No workspace errors. `node_modules/.pnpm/vitest@*` exists.

- [ ] **Step 4: Verify vitest runs (will pass with 0 tests)**

Run: `pnpm test:ui`
Expected: vitest reports `No test files found` and exits with non-zero. This is fine — next task adds the first test.

- [ ] **Step 5: Commit**

```bash
git add ui/package.json package.json pnpm-lock.yaml
git commit -m "Add vitest to ui workspace for scrubber tests"
```

---

## Task 3: Write scrubber tests (failing)

**Files:**
- Create: `ui/sentry/scrubbers.test.js`

**Why:** TDD. Lock in the privacy behavior with tests before implementation so regressions are caught.

- [ ] **Step 1: Write the failing test file**

Create `ui/sentry/scrubbers.test.js`:

```js
import { describe, it, expect } from 'vitest'
import { scrubString, scrubUrl, beforeSend, beforeBreadcrumb } from './scrubbers.js'

describe('scrubString', () => {
  it('collapses absolute user paths to ~/', () => {
    expect(scrubString('/Users/vladyslav/Movies/x.mkv')).toBe('~/Movies/*.mkv')
    expect(scrubString('/home/vlad/video.mp4')).toBe('~/*.mp4')
  })

  it('strips media filename stems, keeping extension', () => {
    expect(scrubString('Failed to transcode The.Sopranos.S01E03.mkv'))
      .toBe('Failed to transcode *.mkv')
    expect(scrubString('movie.MP4')).toBe('*.mp4')
  })

  it('is case-insensitive for media extensions', () => {
    expect(scrubString('/Users/a/x.MKV')).toBe('~/*.mkv')
  })

  it('redacts TVMaze/IMDb search terms', () => {
    expect(scrubString('Failed to fetch TVMaze: Sopranos'))
      .toBe('Failed to fetch TVMaze: <redacted>')
    expect(scrubString('Failed to fetch IMDb search: The Matrix'))
      .toBe('Failed to fetch IMDb search: <redacted>')
  })

  it('leaves non-sensitive strings unchanged', () => {
    expect(scrubString('ECONNREFUSED 127.0.0.1:3001'))
      .toBe('ECONNREFUSED 127.0.0.1:3001')
  })

  it('handles non-string input by returning it unchanged', () => {
    expect(scrubString(undefined)).toBe(undefined)
    expect(scrubString(null)).toBe(null)
    expect(scrubString(42)).toBe(42)
  })
})

describe('scrubUrl', () => {
  it('replaces numeric id segments with :id', () => {
    expect(scrubUrl('/api/series/42/episodes/7'))
      .toBe('/api/series/:id/episodes/:id')
  })

  it('replaces UUID segments with :id', () => {
    expect(scrubUrl('/session/3f8e8a41-2b4c-4d5e-9f0a-1b2c3d4e5f6a/start'))
      .toBe('/session/:id/start')
  })

  it('strips query strings entirely', () => {
    expect(scrubUrl('/search?q=sopranos&page=2')).toBe('/search')
  })

  it('preserves non-id path segments', () => {
    expect(scrubUrl('/api/health')).toBe('/api/health')
  })

  it('handles absolute URLs', () => {
    expect(scrubUrl('http://localhost:3001/api/series/42?t=1'))
      .toBe('http://localhost:3001/api/series/:id')
  })

  it('handles non-string input by returning it unchanged', () => {
    expect(scrubUrl(undefined)).toBe(undefined)
    expect(scrubUrl(null)).toBe(null)
  })
})

describe('beforeSend', () => {
  it('scrubs message, exception value, stack filenames, request url', () => {
    const event = {
      message: 'Failed to transcode /Users/vladyslav/Movies/x.mkv',
      exception: {
        values: [
          {
            value: 'Cannot read /Users/vladyslav/a.mkv',
            stacktrace: {
              frames: [
                { filename: '/Users/vladyslav/code/caramba/web/src/App.jsx' },
              ],
            },
          },
        ],
      },
      request: { url: 'http://localhost:3001/api/series/42?t=1' },
    }
    const result = beforeSend(event)
    expect(result.message).toBe('Failed to transcode ~/Movies/*.mkv')
    expect(result.exception.values[0].value).toBe('Cannot read ~/*.mkv')
    expect(result.exception.values[0].stacktrace.frames[0].filename)
      .toBe('~/code/caramba/web/src/App.jsx')
    expect(result.request.url).toBe('http://localhost:3001/api/series/:id')
  })

  it('returns the same event object (mutates in place is fine)', () => {
    const event = { message: 'ok' }
    expect(beforeSend(event)).toBe(event)
  })

  it('tolerates missing optional fields', () => {
    expect(beforeSend({})).toEqual({})
  })
})

describe('beforeBreadcrumb', () => {
  it('scrubs message and data.url and data.to', () => {
    const crumb = {
      message: 'Navigation to /series/42',
      data: {
        url: 'http://localhost:3001/api/series/42?t=1',
        to: '/series/42/episode/7',
      },
    }
    const result = beforeBreadcrumb(crumb)
    expect(result.message).toBe('Navigation to /series/:id')
    expect(result.data.url).toBe('http://localhost:3001/api/series/:id')
    expect(result.data.to).toBe('/series/:id/episode/:id')
  })

  it('tolerates missing data', () => {
    expect(beforeBreadcrumb({ message: 'x' })).toEqual({ message: 'x' })
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test:ui`
Expected: Tests fail with `Failed to load url ./scrubbers.js` (module not found). This is the expected failure — implementation comes next.

- [ ] **Step 3: Commit**

```bash
git add ui/sentry/scrubbers.test.js
git commit -m "Add failing scrubber tests for PII redaction rules"
```

---

## Task 4: Implement scrubbers

**Files:**
- Create: `ui/sentry/scrubbers.js`

- [ ] **Step 1: Write implementation**

Create `ui/sentry/scrubbers.js`:

```js
const MEDIA_EXT = '(mkv|mp4|avi|webm|m4v|mov|mp3|flac|srt|vtt|ass)'
const HOME_PATH_RE = /\/(Users|home)\/[^/\s]+\//g
const MEDIA_FILE_RE = new RegExp(`[\\w.\\-\\s]+\\.${MEDIA_EXT}`, 'gi')
const NUMERIC_ID_RE = /\/\d+(?=\/|$|\?)/g
const UUID_RE = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\/|$|\?)/gi
const SEARCH_TERM_RE = /(Failed to fetch (?:TVMaze|IMDb)[^:]*:\s*)(.+)/g

export function scrubString(input) {
  if (typeof input !== 'string') return input
  return input
    .replace(HOME_PATH_RE, '~/')
    .replace(MEDIA_FILE_RE, (match) => {
      const dot = match.lastIndexOf('.')
      return `*${match.slice(dot).toLowerCase()}`
    })
    .replace(SEARCH_TERM_RE, '$1<redacted>')
}

export function scrubUrl(input) {
  if (typeof input !== 'string') return input
  const [base] = input.split('?')
  return base
    .replace(UUID_RE, '/:id')
    .replace(NUMERIC_ID_RE, '/:id')
}

export function beforeSend(event) {
  if (!event) return event
  if (event.message) event.message = scrubString(event.message)
  if (event.request?.url) event.request.url = scrubUrl(event.request.url)
  const values = event.exception?.values
  if (Array.isArray(values)) {
    for (const v of values) {
      if (v.value) v.value = scrubString(v.value)
      const frames = v.stacktrace?.frames
      if (Array.isArray(frames)) {
        for (const f of frames) {
          if (f.filename) f.filename = scrubString(f.filename)
        }
      }
    }
  }
  return event
}

export function beforeBreadcrumb(crumb) {
  if (!crumb) return crumb
  if (crumb.message) crumb.message = scrubString(scrubUrl(crumb.message))
  if (crumb.data) {
    if (crumb.data.url) crumb.data.url = scrubUrl(crumb.data.url)
    if (crumb.data.to) crumb.data.to = scrubUrl(crumb.data.to)
  }
  return crumb
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `pnpm test:ui`
Expected: All 15+ assertions pass, vitest exits 0.

- [ ] **Step 3: Commit**

```bash
git add ui/sentry/scrubbers.js
git commit -m "Implement PII scrubbers for paths, filenames, URL ids, search terms"
```

---

## Task 5: Shared init facade

**Files:**
- Create: `ui/sentry/init.js`
- Create: `ui/sentry/router.js`

**Why:** Each client passes its own `Sentry` SDK (different package per platform) plus DSN + platform tag. Router helper encapsulates the React Router v7 integration boilerplate.

- [ ] **Step 1: Create the router helper**

Create `ui/sentry/router.js`:

```js
import { useEffect } from 'react'
import {
  useLocation,
  useNavigationType,
  createRoutesFromChildren,
  matchRoutes,
} from 'react-router-dom'

export function reactRouterV7Integration(Sentry) {
  if (typeof Sentry.reactRouterV7BrowserTracingIntegration !== 'function') {
    return null
  }
  return Sentry.reactRouterV7BrowserTracingIntegration({
    useEffect,
    useLocation,
    useNavigationType,
    createRoutesFromChildren,
    matchRoutes,
  })
}
```

- [ ] **Step 2: Create the init function**

Create `ui/sentry/init.js`:

```js
import { beforeSend, beforeBreadcrumb } from './scrubbers.js'
import { reactRouterV7Integration } from './router.js'

/**
 * Platform-agnostic Sentry init. Caller passes the Sentry SDK object from
 * whichever package they use (@sentry/react, @sentry/electron/renderer,
 * @sentry/capacitor). Safe to call at most once per process.
 *
 * @param {object} opts
 * @param {object} opts.Sentry        The Sentry SDK object
 * @param {string} opts.dsn           DSN from env; falsy → no-op
 * @param {string} opts.platform      One of: web | desktop-renderer | android-tv
 * @param {string} opts.release       Release identifier (e.g. "caramba@v1.3.7")
 * @param {number} [opts.tracesSampleRate]
 * @param {boolean} [opts.isDev]
 */
export function sentryInit({ Sentry, dsn, platform, release, tracesSampleRate, isDev }) {
  if (!dsn) {
    console.info('[sentry] no DSN provided, skipping init')
    return
  }
  const integrations = []
  if (typeof Sentry.browserTracingIntegration === 'function') {
    integrations.push(Sentry.browserTracingIntegration())
  }
  const routerIntegration = reactRouterV7Integration(Sentry)
  if (routerIntegration) integrations.push(routerIntegration)

  Sentry.init({
    dsn,
    release,
    environment: isDev ? 'development' : 'production',
    sendDefaultPii: false,
    tracesSampleRate: tracesSampleRate ?? (isDev ? 1.0 : 0.2),
    integrations,
    beforeSend,
    beforeBreadcrumb,
  })
  Sentry.setTag('platform', platform)

  if (typeof window !== 'undefined') {
    window.__SENTRY__ = Sentry
  }
}
```

- [ ] **Step 3: Sanity check — parse with node**

Run: `node --check ui/sentry/init.js && node --check ui/sentry/router.js`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add ui/sentry/init.js ui/sentry/router.js
git commit -m "Add SDK-agnostic Sentry init facade and React Router v7 integration helper"
```

---

## Task 6: ErrorBoundary → Sentry

**Files:**
- Modify: `ui/components/ErrorBoundary.jsx`

- [ ] **Step 1: Edit componentDidCatch**

In `ui/components/ErrorBoundary.jsx`, replace:

```js
  componentDidCatch(error, errorInfo) {
    console.error('[ErrorBoundary] Uncaught render error:', error, errorInfo)
  }
```

with:

```js
  componentDidCatch(error, errorInfo) {
    console.error('[ErrorBoundary] Uncaught render error:', error, errorInfo)
    if (typeof window !== 'undefined' && window.__SENTRY__?.captureException) {
      window.__SENTRY__.captureException(error, {
        contexts: { react: { componentStack: errorInfo.componentStack } },
      })
    }
  }
```

- [ ] **Step 2: Commit**

```bash
git add ui/components/ErrorBoundary.jsx
git commit -m "Report boundary-caught render errors to Sentry when init"
```

---

## Task 7: Web client — install deps and wire init

**Files:**
- Modify: `web/package.json`
- Create: `web/.env`
- Modify: `web/src/main.jsx`
- Modify: `web/vite.config.js`

**Note:** This task does NOT set the DSN to a real value. Placeholder is used so build + init don't crash; user fills in the real DSN after Task 12.

- [ ] **Step 1: Add runtime + build deps**

Modify `web/package.json`, adding to `dependencies` and `devDependencies`:

```json
  "dependencies": {
    "@caramba/ui": "workspace:*",
    "@sentry/react": "^8.40.0"
  },
  "devDependencies": {
    "@sentry/vite-plugin": "^2.22.0",
    "@vitejs/plugin-react": "^4.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "react-router": "^7.0.0",
    "react-router-dom": "^7.0.0",
    "vite": "^6.0.0"
  }
```

Run: `pnpm install`
Expected: packages resolve, no errors.

- [ ] **Step 2: Create `web/.env` with placeholder DSN**

Create `web/.env`:

```
# Sentry DSN for the @caramba/web project. Committed; DSNs are public-by-design.
# Replace this placeholder with the real DSN from https://sentry.io → web project → Client Keys.
VITE_SENTRY_DSN=
```

- [ ] **Step 3: Wire init in main.jsx**

Replace `web/src/main.jsx` contents with:

```jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import * as Sentry from '@sentry/react'
import App from './App'
import ErrorBoundary from '@caramba/ui/components/ErrorBoundary'
import { sentryInit } from '@caramba/ui/sentry/init'
import '@caramba/ui/styles/app.css'

sentryInit({
  Sentry,
  dsn: import.meta.env.VITE_SENTRY_DSN,
  platform: 'web',
  release: __SENTRY_RELEASE__,
  isDev: import.meta.env.DEV,
})

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
)
```

- [ ] **Step 4: Wire vite.config.js**

Replace `web/vite.config.js` contents with:

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import path from 'path'

const SENTRY_RELEASE = process.env.SENTRY_RELEASE || 'dev'

export default defineConfig({
  plugins: [
    react(),
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT_WEB || 'caramba-web',
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: SENTRY_RELEASE },
      sourcemaps: { filesToDeleteAfterUpload: ['dist/**/*.js.map'] },
      disable: !process.env.SENTRY_AUTH_TOKEN,
      telemetry: false,
    }),
  ],
  base: '/',
  define: {
    __SENTRY_RELEASE__: JSON.stringify(SENTRY_RELEASE),
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: false,
        headers: { 'X-Forwarded-Proto': 'http' },
      },
      '/rails': { target: 'http://localhost:3001', changeOrigin: false },
      '/up': { target: 'http://localhost:3001', changeOrigin: true },
    },
  },
  resolve: {
    alias: { '@caramba/ui': path.resolve(__dirname, '../ui') },
  },
})
```

- [ ] **Step 5: Verify build**

Run: `cd web && pnpm build`
Expected: Build succeeds. Console shows `[sentry-vite-plugin] Sentry Vite plugin is disabled (no auth token)` or similar. No source maps uploaded (expected — no token yet).

- [ ] **Step 6: Commit**

```bash
git add web/package.json web/.env web/src/main.jsx web/vite.config.js pnpm-lock.yaml
git commit -m "Wire Sentry into @caramba/web with source map plugin gated on auth token"
```

---

## Task 8: Android TV — install deps and wire init

**Files:**
- Modify: `android-tv/package.json`
- Create: `web/.env.android`
- Modify: `web/src/AppAndroid.jsx`
- Modify: `web/vite.config.android.js`
- Modify: `android-tv/bin/build`
- Modify: `Procfile.android`

- [ ] **Step 1: Add @sentry/capacitor to android-tv**

Modify `android-tv/package.json`, adding to `dependencies`:

```json
  "dependencies": {
    "@caramba/ui": "workspace:*",
    "@capacitor/android": "^6.0.0",
    "@capacitor/core": "^6.0.0",
    "@capacitor/app": "^6.0.0",
    "@capacitor/preferences": "^6.0.0",
    "@sentry/capacitor": "^1.0.0",
    "@sentry/react": "^8.40.0"
  }
```

Run: `pnpm install`
Expected: packages resolve. Note: `@sentry/capacitor` pulls a peer of `@sentry/react`; having it explicit is fine.

- [ ] **Step 2: Create `web/.env.android` with placeholder DSN**

Create `web/.env.android`:

```
# Sentry DSN for the @caramba/android project. Committed; DSNs are public-by-design.
# Picked up by Vite when building with --mode android (bin/android-tv/build).
# Replace this placeholder with the real DSN from https://sentry.io → android-tv project.
VITE_SENTRY_DSN=
```

- [ ] **Step 3: Read current AppAndroid.jsx**

Run: `cat web/src/AppAndroid.jsx | head -40`
Expected: shows whatever the current AppAndroid entry does. Find the top-level `ReactDOM.createRoot(...).render(...)` call or the equivalent bootstrap; init must run before that.

- [ ] **Step 4: Wire init in AppAndroid.jsx**

At the top of `web/src/AppAndroid.jsx`, below the other top-level imports and above any `ReactDOM.createRoot` call, insert:

```jsx
import * as Sentry from '@sentry/capacitor'
import * as SentryReact from '@sentry/react'
import { sentryInit } from '@caramba/ui/sentry/init'

sentryInit({
  Sentry: { ...SentryReact, ...Sentry, init: Sentry.init },
  dsn: import.meta.env.VITE_SENTRY_DSN,
  platform: 'android-tv',
  release: __SENTRY_RELEASE__,
  isDev: import.meta.env.DEV,
})
```

The `{ ...SentryReact, ...Sentry }` merge gives us Capacitor's native-crash-capable `init` plus the React-layer helpers (`browserTracingIntegration`, `reactRouterV7BrowserTracingIntegration`, `captureException`).

- [ ] **Step 5: Wire vite.config.android.js**

Replace `web/vite.config.android.js` contents with:

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import path from 'path'

const SENTRY_RELEASE = process.env.SENTRY_RELEASE || 'dev'

export default defineConfig({
  plugins: [
    react(),
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT_ANDROID || 'caramba-android',
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: SENTRY_RELEASE },
      sourcemaps: { filesToDeleteAfterUpload: ['dist/**/*.js.map'] },
      disable: !process.env.SENTRY_AUTH_TOKEN,
      telemetry: false,
    }),
  ],
  base: './',
  define: {
    __SENTRY_RELEASE__: JSON.stringify(SENTRY_RELEASE),
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: true,
    minify: 'terser',
    terserOptions: {
      compress: { drop_console: true },
    },
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: false,
        headers: { 'X-Forwarded-Proto': 'http' },
      },
      '/up': { target: 'http://localhost:3001', changeOrigin: true },
    },
  },
  resolve: {
    alias: { '@caramba/ui': path.resolve(__dirname, '../ui') },
  },
})
```

- [ ] **Step 6: Android build must pass `--mode android`**

Read: `cat android-tv/bin/build | grep -n "pnpm build"`

In `android-tv/bin/build`, change the line `pnpm build` (inside the `# ── 3. Build React frontend ───` section) to:

```bash
pnpm build --mode android
```

This makes Vite load `web/.env.android` on top of `web/.env`, swapping in the android DSN.

- [ ] **Step 7: Android dev (Procfile.android) must also use --mode android**

Modify `Procfile.android`, changing the `web:` line to:

```
web:      cd web && pnpm exec vite --mode android --port 3000 --host
```

- [ ] **Step 8: Verify android build**

Run: `cd web && pnpm build --mode android`
Expected: Build succeeds into `web/dist`. Plugin disabled warning (no token) is fine.

- [ ] **Step 9: Commit**

```bash
git add android-tv/package.json web/.env.android web/src/AppAndroid.jsx web/vite.config.android.js android-tv/bin/build Procfile.android pnpm-lock.yaml
git commit -m "Wire Sentry into android-tv via @sentry/capacitor + --mode android"
```

---

## Task 9: Desktop renderer — install deps and wire init

**Files:**
- Modify: `desktop/package.json`
- Create: `desktop/.env`
- Modify: `desktop/src/main.jsx`
- Modify: `desktop/vite.config.js`

- [ ] **Step 1: Add deps to desktop**

Modify `desktop/package.json`, adding to `dependencies` and `devDependencies`:

```json
  "dependencies": {
    "@caramba/ui": "workspace:*",
    "@sentry/electron": "^5.10.0",
    "better-sqlite3": "^11.0.0",
    "bonjour-service": "^1.3.0"
  },
  "devDependencies": {
    "@electron/rebuild": "^4.0.3",
    "@sentry/vite-plugin": "^2.22.0",
    "@vitejs/plugin-react": "^4.0.0",
    "electron": "^33.0.0",
    "electron-builder": "^25.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "react-router": "^7.0.0",
    "react-router-dom": "^7.0.0",
    "vite": "^6.0.0"
  }
```

Run: `pnpm install`
Expected: packages resolve.

- [ ] **Step 2: Create `desktop/.env` with placeholder DSN**

Create `desktop/.env`:

```
# Sentry DSN for the @caramba/desktop project. Committed; DSNs are public-by-design.
# Used by both the Vite renderer (VITE_ prefix) and the Electron main process (SENTRY_DSN).
# Replace this placeholder with the real DSN from https://sentry.io → desktop project.
VITE_SENTRY_DSN=
SENTRY_DSN=
```

- [ ] **Step 3: Wire init in desktop/src/main.jsx**

Replace `desktop/src/main.jsx` contents with:

```jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import * as Sentry from '@sentry/electron/renderer'
import App from './App'
import ErrorBoundary from '@caramba/ui/components/ErrorBoundary'
import { sentryInit } from '@caramba/ui/sentry/init'
import '@caramba/ui/styles/app.css'

sentryInit({
  Sentry,
  dsn: import.meta.env.VITE_SENTRY_DSN,
  platform: 'desktop-renderer',
  release: __SENTRY_RELEASE__,
  isDev: import.meta.env.DEV,
})

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
)
```

- [ ] **Step 4: Wire desktop/vite.config.js**

Replace `desktop/vite.config.js` contents with:

```js
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { sentryVitePlugin } from '@sentry/vite-plugin'
import path from 'path'

const SENTRY_RELEASE = process.env.SENTRY_RELEASE || 'dev'

export default defineConfig({
  plugins: [
    react(),
    sentryVitePlugin({
      org: process.env.SENTRY_ORG,
      project: process.env.SENTRY_PROJECT_DESKTOP || 'caramba-desktop',
      authToken: process.env.SENTRY_AUTH_TOKEN,
      release: { name: SENTRY_RELEASE },
      sourcemaps: { filesToDeleteAfterUpload: ['dist-react/**/*.js.map'] },
      disable: !process.env.SENTRY_AUTH_TOKEN,
      telemetry: false,
    }),
  ],
  base: './',
  define: {
    __SENTRY_RELEASE__: JSON.stringify(SENTRY_RELEASE),
  },
  build: {
    outDir: 'dist-react',
    emptyOutDir: true,
    sourcemap: true,
  },
  server: { port: 5173 },
  resolve: {
    alias: { '@caramba/ui': path.resolve(__dirname, '../ui') },
  },
})
```

- [ ] **Step 5: Verify desktop renderer build**

Run: `cd desktop && pnpm build`
Expected: Build succeeds into `desktop/dist-react`. No upload (no token).

- [ ] **Step 6: Commit**

```bash
git add desktop/package.json desktop/.env desktop/src/main.jsx desktop/vite.config.js pnpm-lock.yaml
git commit -m "Wire Sentry into desktop renderer via @sentry/electron"
```

---

## Task 10: Desktop main process init

**Files:**
- Create: `desktop/electron/sentry.js`
- Modify: `desktop/electron/main.js`

**Why:** `@sentry/electron/main` must be initialized **before** the `app` module is ready to capture unhandled exceptions from early bootstrap code.

- [ ] **Step 1: Create electron main init**

Create `desktop/electron/sentry.js`:

```js
const Sentry = require('@sentry/electron/main')
const path = require('path')
const fs = require('fs')

function loadDotenv() {
  const envPath = path.join(__dirname, '..', '.env')
  try {
    const raw = fs.readFileSync(envPath, 'utf8')
    for (const line of raw.split('\n')) {
      const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/)
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2]
    }
  } catch {
    // .env missing in packaged builds; env vars are expected to be set elsewhere.
  }
}

loadDotenv()

const dsn = process.env.SENTRY_DSN
if (dsn) {
  Sentry.init({
    dsn,
    release: process.env.SENTRY_RELEASE || 'dev',
    environment: process.env.NODE_ENV === 'development' ? 'development' : 'production',
    sendDefaultPii: false,
    tracesSampleRate: 0.2,
    initialScope: { tags: { platform: 'desktop-main' } },
  })
} else {
  console.info('[sentry/main] SENTRY_DSN not set, skipping init')
}

module.exports = Sentry
```

- [ ] **Step 2: Wire into main.js at the very top**

Read: `head -n 1 desktop/electron/main.js`
Expected first line: `const { app, BrowserWindow, shell, protocol, net, ipcMain } = require('electron')`

Insert this as the FIRST line of `desktop/electron/main.js`, above everything else:

```js
const Sentry = require('./sentry')
```

- [ ] **Step 3: Verify electron main loads**

Run (Electron-only mode per CLAUDE.md): `cd desktop && pnpm electron`
Expected: App launches. Console shows either `[sentry/main] SENTRY_DSN not set, skipping init` (if DSN blank) or successful init.

Close the app after confirming.

- [ ] **Step 4: Commit**

```bash
git add desktop/electron/sentry.js desktop/electron/main.js
git commit -m "Init @sentry/electron/main at the top of the Electron main entry"
```

---

## Task 11: Explicit capture for transcoder + updater failures

**Files:**
- Modify: `desktop/electron/services/transcoder.js`
- Modify: `desktop/electron/services/updater.js`

**Why:** ffmpeg spawn failures and auto-updater download failures are silent from the user's perspective — we want them visible in Sentry. Only `spawn error` is wrapped for transcoder (non-zero exit is normal for cancelled playback).

- [ ] **Step 1: Read current transcoder error paths**

Run: `grep -n "proc.on('error'" desktop/electron/services/transcoder.js`
Expected: two matches around lines 341 and 397 (spawn error handlers).

- [ ] **Step 2: Wrap the two spawn error handlers**

For each `proc.on('error', (err) => { ... })` block in `desktop/electron/services/transcoder.js`, add at the top of the handler body:

```js
try { require('@sentry/electron/main').captureException(err, { tags: { subsystem: 'transcoder' } }) } catch {}
```

The try/catch prevents a Sentry failure from masking the real error. Do not wrap `proc.on('exit', ...)` — non-zero exit is normal for cancelled playback.

- [ ] **Step 3: Read current updater error paths**

Run: `grep -n "reject\|\.catch\|on('error'" desktop/electron/services/updater.js`
Expected: shows promise-rejection sites and error event handlers.

- [ ] **Step 4: Add capture on the download-failure path**

In `desktop/electron/services/updater.js`, inside the Promise-based download function (the one with `out.on('error', reject)` around line 194), wrap the `reject` callbacks that fire on actual network/filesystem errors. For each `out.on('error', reject)` and `res.on('error', reject)`, replace with:

```js
out.on('error', (err) => {
  try { require('@sentry/electron/main').captureException(err, { tags: { subsystem: 'updater' } }) } catch {}
  reject(err)
})
```

(and the analogous for `res.on('error'`). Do NOT wrap "update not available" conditions — those are normal flow.

- [ ] **Step 5: Smoke-test desktop still builds**

Run: `cd desktop && pnpm build`
Expected: renderer builds cleanly. Electron main is uncompiled JS — no build step.

- [ ] **Step 6: Commit**

```bash
git add desktop/electron/services/transcoder.js desktop/electron/services/updater.js
git commit -m "Capture ffmpeg spawn + updater download failures to Sentry"
```

---

## Task 12: Release tagging in bin/build

**Files:**
- Modify: `desktop/bin/build`
- Modify: `android-tv/bin/build`

**Why:** After bumping the root version, we must export `SENTRY_RELEASE` so Vite plugin, Electron main, and the runtime `define` all see the same value.

- [ ] **Step 1: Export release from desktop/bin/build**

Read: `cat desktop/bin/build | grep -n -A3 "NEW_VERSION=\|CURRENT_VERSION="`

In `desktop/bin/build`, after the version determination section (after the block that sets `CURRENT_VERSION` and, if present, `NEW_VERSION`), add:

```bash
# Export the release tag for @sentry/vite-plugin and the runtime.
FINAL_VERSION="${NEW_VERSION:-$CURRENT_VERSION}"
export SENTRY_RELEASE="caramba@${FINAL_VERSION#v}"
echo "Sentry release: $SENTRY_RELEASE"
```

Place this line just before the Vite / electron-builder invocation so the env var is set when the build runs.

- [ ] **Step 2: Export release from android-tv/bin/build**

In `android-tv/bin/build`, right after the `CURRENT_VERSION=$(node ...)` line, add:

```bash
export SENTRY_RELEASE="caramba@${CURRENT_VERSION#v}"
echo "Sentry release: $SENTRY_RELEASE"
```

- [ ] **Step 3: Dry-run desktop build, token-less**

Run (no `--publish`): `bin/build --desktop`
Expected: Build completes. Console line `Sentry release: caramba@X.Y.Z`. Plugin reports it is disabled (no auth token).

- [ ] **Step 4: Commit**

```bash
git add desktop/bin/build android-tv/bin/build
git commit -m "Export SENTRY_RELEASE from build scripts for source map tagging"
```

---

## Task 13: Populate the real DSNs and auth token

**Files:**
- Modify: `web/.env`, `web/.env.android`, `desktop/.env`
- Create (outside git): `.env.local` at repo root
- No commit for this task (DSNs are the user's to paste in; this plan documents the how)

**Why:** The plan intentionally left placeholder DSNs. This task documents the one-time manual step.

- [ ] **Step 1: Fetch the three DSNs from Sentry**

For each project at https://sentry.io/settings/projects/: open → Client Keys (DSN) → copy the DSN URL.

- [ ] **Step 2: Paste into the three committed files**

- `web/.env` → `VITE_SENTRY_DSN=https://...ingest.sentry.io/...`
- `web/.env.android` → `VITE_SENTRY_DSN=https://...`
- `desktop/.env` → both `VITE_SENTRY_DSN=...` and `SENTRY_DSN=...` (same value, different consumers)

- [ ] **Step 3: Create `.env.local` at the repo root (NOT committed, gitignored)**

Run (from repo root):

```bash
cat > .env.local <<'EOF'
# Sentry auth token for source map uploads. Generate at
#   https://sentry.io/settings/auth-tokens/ with scopes: project:releases + project:read
# Gitignored — never commit.
SENTRY_AUTH_TOKEN=
SENTRY_ORG=<your-sentry-org-slug>
SENTRY_PROJECT_WEB=<web-project-slug>
SENTRY_PROJECT_ANDROID=<android-project-slug>
SENTRY_PROJECT_DESKTOP=<desktop-project-slug>
EOF
```

Fill in the values. Confirm it is gitignored: `git check-ignore -v .env.local` should print the matching `.gitignore` rule.

- [ ] **Step 4: Teach the build scripts to source `.env.local`**

At the top of `desktop/bin/build` (after `cd "$(dirname "$0")/.."; ROOT_DIR="$(cd .. && pwd)"`), add:

```bash
if [ -f "$ROOT_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env.local"
  set +a
fi
```

Add the identical block near the top of `android-tv/bin/build`.

- [ ] **Step 5: Commit the sourcing change (the DSN/token files themselves remain as user-owned edits)**

```bash
git add desktop/bin/build android-tv/bin/build
git commit -m "Source .env.local from build scripts so SENTRY_AUTH_TOKEN reaches the Vite plugin"
```

---

## Task 14: Verification — end-to-end

**Files:** none (manual verification)

**Why:** Spec's verification section. Walking through each client with a forced error confirms the wiring.

- [ ] **Step 1: Run scrubber tests**

Run: `pnpm test:ui`
Expected: all pass, 0 failures.

- [ ] **Step 2: Desktop renderer smoke test**

Run: `bin/desktop`

In a React component (temporarily, then revert), add a button whose `onClick` does `throw new Error('sentry-test-renderer')`. Click it. Wait ~30s. In Sentry dashboard → desktop project → Issues, confirm:

- Issue `Error: sentry-test-renderer` appears.
- Tag `platform: desktop-renderer`.
- Stack frame filenames start with `~/` (not `/Users/<you>/`).
- If `SENTRY_AUTH_TOKEN` was set and a production build was used, source lines are readable (not minified).

Revert the temporary throw.

- [ ] **Step 3: Desktop main smoke test**

Add to `desktop/electron/main.js` (temporarily, then revert), below the `const Sentry = require('./sentry')` line:

```js
setTimeout(() => { throw new Error('sentry-test-main') }, 5000)
```

Run: `cd desktop && pnpm electron`

Wait 10s. Confirm in Sentry desktop project:

- Issue `Error: sentry-test-main` appears.
- Tag `platform: desktop-main`.

Revert the temporary throw.

- [ ] **Step 4: Web smoke test**

Run: `bin/web`

In any page add a temporary button that throws. Confirm issue appears in the **web** Sentry project tagged `platform: web`.

Revert.

- [ ] **Step 5: Android TV smoke test**

Run: `bin/android`

Trigger an error in the app. Confirm issue appears in the **android** Sentry project tagged `platform: android-tv`.

Revert.

- [ ] **Step 6: Performance transaction check**

In Sentry → Performance, for each project, confirm at least one transaction named after a React Router navigation path appeared during the above runs.

- [ ] **Step 7: Breadcrumb scrubbing check**

In a real error's breadcrumbs, confirm URLs show `/api/series/:id` rather than `/api/series/42`, and no query strings leak.

- [ ] **Step 8: Source map upload check (optional, requires auth token)**

With `SENTRY_AUTH_TOKEN` in `.env.local`, run `bin/build --desktop`. Confirm:

- Build output contains `[sentry-vite-plugin] Successfully uploaded source maps...`
- Sentry → Releases shows the version just built with "Artifacts uploaded".
- `desktop/dist-react/**/*.js.map` is empty (files deleted after upload).

---

## Open-task cleanup note

Tasks 13 and 14 include manual actions (pasting DSNs, triggering smoke errors). They are not automatable from this plan. The engineer executing the plan should check them off only after performing the real actions — do not mark complete based on running `sed` or similar shortcuts.

---

## Self-review

**Spec coverage:**
- Telemetry level (errors + perf): Task 5 (`tracesSampleRate`), Task 7/8/9/10.
- DSN distribution (committed .env): Task 1 (gitignore), Task 7/8/9 (.env files).
- Source maps + release: Task 7/8/9 (vite plugin), Task 12 (SENTRY_RELEASE), Task 13 (auth token).
- Aggressive scrubbing: Tasks 3, 4.
- Electron main error capture: Tasks 10, 11.
- Error Boundary: Task 6.
- Platform tag convention: Tasks 5 (`Sentry.setTag`), 10 (`initialScope.tags`).
- Out of scope correctly not covered: Rails, session replay, feedback widget, session health.

**Placeholder scan:** None found — every step has real code or a concrete command. DSN values are placeholders *by design* (Task 13).

**Type consistency:** `sentryInit` options are consistent across Tasks 5, 7, 8, 9. `window.__SENTRY__` handle set in Task 5 and consumed in Task 6. `SENTRY_RELEASE` env var set in Task 12 and consumed by all three vite configs (Tasks 7/8/9) and Electron main (Task 10). Release format `caramba@<version-without-v>` is consistent across build scripts and runtime.

**Gap found and fixed during review:** Task 11 originally said "wrap the error handler" without specifying *which* error handlers. Tightened to name the two `proc.on('error', ...)` sites and explicitly exclude `proc.on('exit', ...)`. Similarly, Task 10 originally said "require at top of main.js" — verified by reading the current first line and making it explicit as "insert as the first line, above `const { app, ... } = require('electron')`".
