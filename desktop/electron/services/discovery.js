// mDNS discovery for Caramba API servers. Uses the pure-JS bonjour-service
// library (Mac/Linux/Windows) so the Electron client isn't tied to a
// specific platform's mDNS tooling. The server side is free to advertise
// however it likes — macOS `dns-sd`, Linux `avahi-publish`, a Ruby gem —
// because mDNS is the wire protocol that matters, not the library.
//
// Exposes a single pure-Node function so it can be unit-tested without
// Electron. `fetchHealth` is injected so tests can use Node's http.get
// and production uses the same.

const { Bonjour } = require('bonjour-service')

const DEFAULT_SCAN_MS = 3000

function log(...args) {
  if (process.env.CARAMBA_DEBUG_DISCOVERY === '0') return
  console.log('[discovery]', ...args)
}

/**
 * @param {object} opts
 * @param {number} [opts.scanMs]           how long to browse (default 3000)
 * @param {(url: string) => Promise<object|null>} opts.fetchHealth
 *        resolves the JSON body from `${url}/api/health`, or null on any
 *        failure; used to verify each candidate before returning
 * @returns {Promise<Array<{ name, host, port, url, version }>>}
 */
async function scanForServers({ scanMs = DEFAULT_SCAN_MS, fetchHealth } = {}) {
  if (typeof fetchHealth !== 'function') {
    throw new TypeError('scanForServers: fetchHealth is required')
  }

  const candidates = await browseForCandidates(scanMs)
  log(`browse returned ${candidates.length} candidate(s): ${JSON.stringify(candidates)}`)

  const verified = await Promise.all(
    candidates.map(async (c) => {
      const health = await fetchHealth(`${c.url}/api/health`)
      if (!health || health.status !== 'ok') {
        log(`reject ${c.url} → ${health ? 'status=' + health.status : 'no response'}`)
        return null
      }
      log(`accept ${c.url} → ${health.server_name || c.name}`)
      return {
        name: health.server_name || c.name,
        host: c.host,
        port: c.port,
        url: c.url,
        version: health.version || c.version || null,
      }
    })
  )

  const seen = new Set()
  return verified.filter(r => r && (seen.has(r.url) ? false : (seen.add(r.url), true)))
}

/**
 * Browse for `_caramba._tcp` services for `scanMs` and return a
 * de-duplicated list of candidates. Strict type check guards against
 * bonjour-service leaking unrelated services ('up' events firing for
 * records that don't match the subscribed type).
 */
function browseForCandidates(scanMs) {
  return new Promise((resolve) => {
    const out = new Map()
    const bonjour = new Bonjour()
    let browser

    const finish = () => {
      try { browser?.stop() } catch {}
      try { bonjour.destroy() } catch {}
      resolve(Array.from(out.values()))
    }

    try {
      browser = bonjour.find({ type: 'caramba', protocol: 'tcp' })
    } catch (err) {
      log(`bonjour.find failed: ${err.message}`)
      finish()
      return
    }

    browser.on('up', (service) => {
      // Strict: service.type must equal 'caramba' — bonjour-service has
      // been observed emitting events for adjacent PTR records.
      if (service.type !== 'caramba') {
        log(`ignore non-caramba service: type=${service.type} name=${service.name}`)
        return
      }
      const host = pickIPv4(service) || pickIPv6(service) || service.host
      const port = service.port
      if (!host || !port) return
      const key = `${host}:${port}`
      if (out.has(key)) return
      const txt = service.txt || {}
      out.set(key, {
        name: txt.name || service.name || host,
        host,
        port,
        url: `http://${host}:${port}`,
        version: txt.version || null,
      })
    })

    browser.on('error', (err) => {
      log(`browser error: ${err?.message || err}`)
    })

    setTimeout(finish, scanMs)
  })
}

function pickIPv4(service) {
  const addrs = service.addresses || []
  for (const a of addrs) {
    if (/^\d+\.\d+\.\d+\.\d+$/.test(a)) return a
  }
  return null
}

function pickIPv6(service) {
  const addrs = service.addresses || []
  for (const a of addrs) {
    if (a.includes(':')) return `[${a}]`
  }
  return null
}

module.exports = { scanForServers, browseForCandidates }
