---
name: adapter-parity
description: Verify a method or capability exists on all three adapters (ui/adapters/local.js, http.js, hybrid.js) and on desktop/electron/preload.js. Run after adding, renaming, or removing any API surface. Flags missing methods, missing noopAsync stubs in http.js, and capability-object drift.
---

# Adapter parity check

Caramba's `ui/` code calls the API exclusively through `useApi()`. Three adapters back that context:

- `ui/adapters/local.js` — Electron, calls `window.api.*` (the bridge in `desktop/electron/preload.js`)
- `ui/adapters/http.js` — pure fetch against Rails `/api/*`
- `ui/adapters/hybrid.js` — desktop "API mode": HTTP-first with IPC fallback

CLAUDE.md rule: *a capability missing from `http.js` should be a `noopAsync`, not absent — hybrid depends on the full shape*. This skill enforces that.

## Procedure

1. **Extract method names from all four files.** Use Grep with these patterns (one per file). Each adapter exports an object literal; pull the property names:

   ```
   ui/adapters/local.js   → grep '^\s*[a-zA-Z_][a-zA-Z0-9_]*\s*[:(]' (top-level methods of the exported object)
   ui/adapters/http.js    → same
   ui/adapters/hybrid.js  → same
   desktop/electron/preload.js → grep inside contextBridge.exposeInMainWorld('api', { ... })
   ```

   Read each file with the Read tool first if the structure is unclear — don't guess from grep output alone.

2. **Build the four sets** (mentally or in a small list): `L`, `H`, `Y`, `P`.

3. **Report these specific mismatches:**
   - `L \ P` — method in `local.js` with no matching `window.api.*` bridge in `preload.js`. Broken IPC at runtime.
   - `L \ H` — method present in `local.js` but absent in `http.js`. Must be added to `http.js` as a `noopAsync` (or a real implementation if the server supports it). Absence breaks `hybrid.js`.
   - `(L ∪ H) \ Y` — method on either side but not handled in `hybrid.js`. `hybrid.js` needs an explicit choice for every method (HTTP-first, IPC-only, or noop).
   - Any name still referenced from `ui/` but removed from all three adapters (orphan call site).

4. **Capability-object sync.** Three capability objects gate UI features:
   - `localCapabilities` (in `ui/adapters/local.js` or near it)
   - `httpCapabilities` (in `ui/adapters/http.js` or near it)
   - `androidTvCapabilities` (defined inline in `web/src/App.jsx`)

   List every capability key. Flag any key that exists in one object but not the others, or where the boolean clearly contradicts what the adapter actually does.

5. **Output.** Terse, structured, no preamble:

   ```
   ## Adapter surface
   local.js: N methods
   http.js: N methods (M noopAsync)
   hybrid.js: N methods
   preload.js: N bridges

   ### Mismatches
   - <method>: missing in <file>  →  <fix>
   ...
   (or: "All four surfaces aligned.")

   ## Capabilities
   - <key>: local=<bool> http=<bool> androidTv=<bool>  ← <flag if drifted>
   ...
   (or: "All capability keys consistent.")
   ```

## When NOT to use this skill

- Pure `ui/` component work that doesn't add or remove API calls.
- Server-only changes that don't add an endpoint.
- Touching `preload.js` only to expose a Node API that isn't part of the adapter contract (rare — most preload additions should round-trip through an adapter).

## Invocation

Type `/adapter-parity` after any change that adds, renames, or removes an adapter method, a `window.api.*` bridge, or a capability key.
