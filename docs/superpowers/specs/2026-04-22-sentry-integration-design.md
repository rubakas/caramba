# Sentry Integration — Design

**Date:** 2026-04-22
**Status:** Approved, ready for implementation plan
**Author:** Vladyslav Davydenko (with Claude)

## Goal

Wire Sentry into the three shipped client apps — `@caramba/web`, `@caramba/desktop`, `@caramba/android` — so errors and performance data from real use flow into three pre-created Sentry projects (one per client), with readable stack traces via uploaded source maps.

## Scope

**In scope**

- Shared Sentry init module under `ui/sentry/`
- React Router v7 navigation transactions (performance tier)
- Source map upload at build time, release tagged with the root `package.json` version
- Aggressive PII scrubbing (paths, filenames, URL IDs, query strings, search terms)
- Electron main-process error capture (unhandled exceptions/rejections, ffmpeg transcoder errors, auto-updater errors)
- Error Boundary → Sentry reporting
- Committed DSNs; gitignored auth token

**Out of scope**

- Rails server Sentry (user created 3 projects, not 4; can add `sentry-ruby` later independently)
- Session replay
- User feedback widget
- Release health / session tracking (`autoSessionTracking`)
- CI-driven source map uploads (builds are local only today)

## Decisions

| # | Decision | Chosen | Why |
|---|---|---|---|
| 1 | Telemetry level | Errors + performance traces | User picked option 2 of three offered |
| 2 | DSN distribution | Committed `.env` per client | DSNs are public-by-design; simplest; no missing-env surprises |
| 3 | Source maps + release tagging | Full pipeline via `@sentry/vite-plugin` | Minified Android TV bundles would otherwise be unreadable |
| 4 | PII scrubbing | Aggressive (paths, filenames, URL IDs, query, search terms) | User priority is privacy-first |
| 5 | Code shape | Shared `ui/sentry/` + per-client init call | Matches the existing adapter pattern; one place to tune scrubber |

## Architecture

```
ui/
  sentry/
    init.js           # sentryInit({ dsn, platform, release, tracesSampleRate })
    scrubbers.js      # beforeSend + beforeBreadcrumb hooks (pure functions)
    router.js         # reactRouterV7BrowserTracingIntegration wrapper
    scrubbers.test.js # (only JS test in the repo — worth it for correctness)
  components/
    ErrorBoundary.jsx # extended: Sentry.captureException in componentDidCatch

web/src/main.jsx            -> sentryInit({ platform: 'web' })
desktop/src/main.jsx        -> sentryInit({ platform: 'desktop-renderer' })
web/src/AppAndroid.jsx      -> sentryInit({ platform: 'android-tv' })
desktop/electron/sentry.js  -> @sentry/electron/main init (loaded at the top of main.js)
```

### Process/SDK matrix

| Process | SDK package | Init location |
|---|---|---|
| web browser | `@sentry/react` | `web/src/main.jsx` via `ui/sentry/init.js` |
| desktop renderer | `@sentry/electron/renderer` + `@sentry/react` | `desktop/src/main.jsx` via `ui/sentry/init.js` |
| desktop main (Node) | `@sentry/electron/main` | `desktop/electron/sentry.js`, required first in `desktop/electron/main.js` |
| android-tv WebView | `@sentry/capacitor` + `@sentry/react` | `web/src/AppAndroid.jsx` via `ui/sentry/init.js` |

`@sentry/electron` pipes renderer events through main, so both processes land in the single `desktop` project under a unified session.

Every `sentryInit` call sets `Sentry.setTag('platform', <value>)` with one of: `web`, `desktop-renderer`, `desktop-main`, `android-tv`. This is the primary filter you'll use in the Sentry UI to separate renderer crashes from Node-side crashes inside the unified desktop project.

## Packages

| Workspace | Add (runtime) | Add (dev/build) |
|---|---|---|
| `ui/` | — (no SDK imports; facade pattern) | — |
| `web/` | `@sentry/react` | `@sentry/vite-plugin` |
| `desktop/` | `@sentry/electron` | `@sentry/vite-plugin` |
| `android-tv/` | `@sentry/capacitor` + `@sentry/react` | — |

`ui/sentry/init.js` and `ui/sentry/router.js` both take the `Sentry` SDK object as a parameter from the caller — no `@sentry/*` import inside `ui/`. Reason: desktop renderer uses `@sentry/electron/renderer` (which re-exports the React SDK surface), web uses `@sentry/react` directly, android uses `@sentry/capacitor`. A hard dependency in `ui/` on any one of those would collide. The facade pattern keeps `ui/` SDK-agnostic and makes scrubber testable without installing Sentry in `ui/`.

## Configuration files

### Committed

- `web/.env` — `VITE_SENTRY_DSN=<web-dsn>`
- `web/.env.android` — `VITE_SENTRY_DSN=<android-dsn>` (picked up when `vite build --mode android` runs, via Vite's built-in mode-based env loading)
- `desktop/.env` — `VITE_SENTRY_DSN=<desktop-dsn>` (used by both main via `process.env` loader and renderer via Vite)

### Gitignored

- `.env.local` at repo root — `SENTRY_AUTH_TOKEN=<token>`
- `.gitignore` entry: `.env.local` and `*.env.local`

The android-tv workspace does **not** own its DSN file. The android build runs from `web/` with a different Vite config, and Vite's mode system is the cleanest way to swap DSN without touching build scripts.

## DSN + release propagation

### Build time

1. `bin/build` writes the bumped version to root `package.json` and commits (existing behavior — no change).
2. `bin/build` reads the post-bump version and exports `SENTRY_RELEASE=caramba@<version>` into the environment of the child Vite / Electron-builder calls.
3. Each Vite config (`web/vite.config.js`, `web/vite.config.android.js`, `desktop/vite.config.js`) adds `sentryVitePlugin({ org, project, authToken: process.env.SENTRY_AUTH_TOKEN, release: { name: process.env.SENTRY_RELEASE }, sourcemaps: { filesToDeleteAfterUpload: ['dist/**/*.map'] } })`.
4. Vite `define`: `__SENTRY_RELEASE__: JSON.stringify(process.env.SENTRY_RELEASE || 'dev')` so runtime `Sentry.init` can tag events with the same string.
5. Electron main reads `process.env.SENTRY_RELEASE` directly — no `define` needed in the main process.

### Missing auth token

If `SENTRY_AUTH_TOKEN` is absent, the plugin logs a warning and skips upload. Local `pnpm dev` / `pnpm electron` builds never upload source maps.

## Scrubbing rules

`ui/sentry/scrubbers.js` exports two functions: `beforeSend(event)` and `beforeBreadcrumb(breadcrumb)`. Both are pure. They apply the following transforms to `event.message`, `event.exception.values[].value`, `event.exception.values[].stacktrace.frames[].filename`, `event.request.url`, `breadcrumb.message`, `breadcrumb.data.url`, and `breadcrumb.data.to`:

| Rule | Pattern | Example transform |
|---|---|---|
| Absolute POSIX user path | `/(Users\|home)/[^/]+/` | `/Users/vladyslav/Movies/x.mkv` → `~/Movies/x.mkv` |
| Media filename with stem | `[\w.\-\s]+\.(mkv\|mp4\|avi\|webm\|m4v\|mov\|mp3\|flac\|srt\|vtt\|ass)` (case-insensitive) | `The.Sopranos.S01E03.mkv` → `*.mkv` (extension preserved literally) |
| Numeric URL ID | `/(\d+)(?=/\|$\|\?)` | `/api/series/42/episodes/7` → `/api/series/:id/episodes/:id` |
| UUID URL ID | `/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=/\|$\|\?)` (case-insensitive) | `/session/3f8e...` → `/session/:id` |
| Query string | `\?.+$` on any URL | `?q=sopranos` → dropped |
| TVMaze/IMDb search term in message | `(?:Failed to fetch (?:TVMaze\|IMDb)[^:]*):\s*(.+)` | `"Failed to fetch TVMaze: Sopranos"` → `"Failed to fetch TVMaze: <redacted>"` |

Plus `sendDefaultPii: false` (default; keeps IPs out).

**Tests:** `ui/sentry/scrubbers.test.js` covers each rule. This will be the first JS test in the repo; we'll add a `vitest` dev dep to `ui/` and a script to `package.json` at repo root.

## Error Boundary integration

`ui/components/ErrorBoundary.jsx` — extend `componentDidCatch`:

```js
componentDidCatch(error, errorInfo) {
  console.error('[ErrorBoundary] Uncaught render error:', error, errorInfo)
  if (typeof window !== 'undefined' && window.__SENTRY__) {
    window.__SENTRY__.captureException(error, {
      contexts: { react: { componentStack: errorInfo.componentStack } },
    })
  }
}
```

The `window.__SENTRY__` handle is set by `sentryInit` so the boundary stays decoupled from any specific SDK import — keeps ui/ importable without Sentry in environments that don't init it (tests, Storybook-if-ever).

## Performance traces

- Integrations: `browserTracingIntegration()` + `reactRouterV7BrowserTracingIntegration({ useEffect, useLocation, useNavigationType, createRoutesFromChildren, matchRoutes })`.
- `tracesSampleRate`: `import.meta.env.DEV ? 1.0 : 0.2`.
- Fetch calls to `/api/*` are auto-instrumented by `browserTracingIntegration`.
- Electron main: `tracesSampleRate: 0.2` in production, `nodeProfilingIntegration` NOT included (native binary, extra weight; skip).
- Explicit `captureException` wrapping for the two highest-value silent-failure paths:
  - `desktop/electron/services/transcoder.js` — ffmpeg child-process `error` event handler
  - `desktop/electron/services/updater.js` — auto-updater failure callback

## File-by-file impact

**New**

- `ui/sentry/init.js`
- `ui/sentry/scrubbers.js`
- `ui/sentry/scrubbers.test.js`
- `ui/sentry/router.js`
- `desktop/electron/sentry.js`
- `web/.env`, `web/.env.android`
- `desktop/.env`

**Modified**

- `ui/components/ErrorBoundary.jsx` — report to Sentry
- `web/src/main.jsx` — call `sentryInit` before `createRoot`
- `web/src/AppAndroid.jsx` — call `sentryInit` before `createRoot`
- `desktop/src/main.jsx` — call `sentryInit` before `createRoot`
- `desktop/electron/main.js` — `require('./sentry')` at the top
- `desktop/electron/services/transcoder.js` — wrap error handler with `Sentry.captureException`
- `desktop/electron/services/updater.js` — wrap error callbacks with `Sentry.captureException`
- `web/vite.config.js`, `web/vite.config.android.js`, `desktop/vite.config.js` — add `sentryVitePlugin` + `define` for `__SENTRY_RELEASE__`
- `bin/build` — export `SENTRY_RELEASE` from post-bump root version
- `.gitignore` — add `.env.local`, `*.env.local`
- `package.json` (root) — add `test:ui` script running vitest
- Relevant workspace `package.json` files — add SDK deps

## Verification

A complete implementation is verified by, in order:

1. `pnpm install` succeeds, no workspace errors.
2. `cd ui && pnpm test` (vitest) — all scrubber rules pass.
3. `bin/desktop` starts; a thrown error in a React component appears in the desktop Sentry project, tagged `platform: desktop-renderer` (tag set by `sentryInit`), with `~/` in its stack frame filenames (scrubber applied) and readable source in the stack trace (source maps local or uploaded).
4. Intentional `throw new Error('test')` in `desktop/electron/main.js` appears in the desktop project tagged `platform: desktop-main` (tag set by the Electron main init).
5. `bin/web` then trigger an error — appears in the web project.
6. `bin/android` then trigger an error — appears in the android project.
7. One navigation in each client generates a performance transaction visible in Sentry's "Performance" tab.
8. Breadcrumbs on a real error show URLs with IDs replaced by `:id` and no query strings.

## Risks / Open questions

- **Vite mode for android.** Existing `bin/android` wires `vite.config.android.js` directly; need to confirm whether `--mode android` is already passed or must be added. Implementation plan should verify with a quick read of the Procfiles before touching the build.
- **`@sentry/capacitor` and Capacitor 6.** The android-tv workspace uses Capacitor 6; confirm SDK compatibility (`@sentry/capacitor` ≥ 1.0 supports Capacitor 6). If there is a version gap, fall back to `@sentry/react` alone in the WebView — this loses native crash reporting but still captures JS errors.
- **Transcoder child-process error vs. exit code.** `services/transcoder.js` has both `error` and `exit` handlers; only `error` (spawn failure) is worth reporting — non-zero exit is normal for e.g. cancelled playback. Implementation should not blanket-wrap `exit`.
- **Auto-updater noise.** `updater.js` fires "update not available" as an event that can look like an error; capture only actual failure callbacks.
