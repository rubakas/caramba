// IPC wrapper around the pure-Node scanner in services/discovery.js.
// We deliberately use Node's plain `http` module for health probing
// (identical to the integration tests) so the production code path is
// the one the test suite exercises. Logs go to stdout so they show up
// in foreman/Electron output when the user runs `bin/desktop`.

const { ipcMain } = require('electron')
const http = require('node:http')
const { URL } = require('node:url')
const { scanForServers } = require('../services/discovery')

const HEALTH_TIMEOUT_MS = 2000

function register() {
  ipcMain.handle('discovery:scan', async () => {
    const started = Date.now()
    console.log('[discovery] scan start')
    try {
      const results = await scanForServers({ fetchHealth: fetchHealthViaNode })
      console.log(`[discovery] scan done in ${Date.now() - started}ms — ${results.length} server(s): ${JSON.stringify(results)}`)
      return results
    } catch (err) {
      console.warn('[discovery] scan failed:', err?.message || err)
      return []
    }
  })
}

function fetchHealthViaNode(urlString) {
  return new Promise((resolve) => {
    let settled = false
    const done = (value) => { if (!settled) { settled = true; resolve(value) } }

    let parsed
    try { parsed = new URL(urlString) } catch { done(null); return }

    const req = http.get({
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      timeout: HEALTH_TIMEOUT_MS,
    }, (res) => {
      if (res.statusCode !== 200) {
        console.log(`[discovery] health ${urlString} → HTTP ${res.statusCode}`)
        done(null); return
      }
      let body = ''
      res.on('data', (c) => { body += c.toString() })
      res.on('end', () => {
        try {
          done(JSON.parse(body))
        } catch (err) {
          console.log(`[discovery] health ${urlString} → bad JSON: ${err.message}`)
          done(null)
        }
      })
      res.on('error', (err) => {
        console.log(`[discovery] health ${urlString} → response error: ${err.message}`)
        done(null)
      })
    })
    req.on('error', (err) => {
      console.log(`[discovery] health ${urlString} → request error: ${err.message}`)
      done(null)
    })
    req.on('timeout', () => {
      try { req.destroy() } catch {}
      console.log(`[discovery] health ${urlString} → timeout`)
      done(null)
    })
  })
}

module.exports = { register }
