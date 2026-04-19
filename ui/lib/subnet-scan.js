/**
 * HTTP subnet scan for Caramba API servers.
 *
 * For every IP in the local /24 subnet(s), probe `/api/health` on the
 * known Rails ports. A Caramba server answers with
 * `{status:"ok", server_name, version, ...}`. Any other response (404,
 * timeout, wrong shape) is ignored. The host that responded is the URL
 * we report, so NAT (Android emulator) and multi-interface hosts work.
 *
 * Everything is a pure function; `fetchImpl` and the WebRTC probe are
 * injected so `node --test` can drive the code without real network.
 */

/**
 * Rails ports we probe `/api/health` on. These are the only ports
 * this project's Procfiles and launchd plist ever bind to. A server
 * on a non-standard port falls back to manual URL entry — after one
 * successful connection, `currentUrl` plumbing keeps rediscovery
 * working on that port.
 */
export const APP_PORTS = [3000, 3001]

/**
 * Default fallback subnets when WebRTC doesn't give us the device's
 * LAN IP and there's no saved URL to learn from. Covers common home-
 * router defaults plus the Android emulator's virtual LAN (10.0.2.x;
 * the host is reachable at 10.0.2.2).
 */
export const DEFAULT_FALLBACK_SUBNETS = [
  '192.168.0',
  '192.168.1',
  '192.168.2',
  '192.168.68',
  '10.0.0',
  '10.0.2', // Android emulator NAT — 10.0.2.2 is the host.
]

const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/

/** "192.168.1.42" → "192.168.1". Returns null for any non-IPv4 input. */
export function ipToSubnet(ip) {
  if (typeof ip !== 'string') return null
  const m = ip.match(IPV4_RE)
  if (!m) return null
  for (let i = 1; i <= 4; i += 1) {
    if (parseInt(m[i], 10) > 255) return null
  }
  return `${m[1]}.${m[2]}.${m[3]}`
}

/**
 * Determine the local /24 subnets worth scanning. If WebRTC leaks the
 * device's LAN IP (typical on Electron / desktop browsers) or a saved
 * URL points at one, we scan only that. Otherwise fall back to the
 * common home-router list.
 */
export async function detectLocalSubnets({
  currentUrl = null,
  rtc = defaultRtcProbe,
  fallbacks = DEFAULT_FALLBACK_SUBNETS,
} = {}) {
  const known = new Set()

  try {
    const subnet = ipToSubnet(await rtc())
    if (subnet) known.add(subnet)
  } catch {}

  if (currentUrl) {
    try {
      const subnet = ipToSubnet(new URL(currentUrl).hostname)
      if (subnet) known.add(subnet)
    } catch {}
  }

  if (known.size > 0) return Array.from(known)
  return Array.from(new Set(fallbacks))
}

/**
 * Parallel scan of every `<subnet>.<1..254>` on `APP_PORTS`, probing
 * `/api/health` on each. Bounded concurrency; per-probe abort timeout.
 * Returns a URL-deduped list of `{ name, host, port, url, version }`.
 */
export async function subnetScan({
  subnets,
  ports = APP_PORTS,
  timeoutMs = 2000,
  concurrency = 128,
  fetchImpl = (typeof fetch !== 'undefined' ? fetch : null),
} = {}) {
  if (!fetchImpl) return []
  if (!Array.isArray(subnets) || subnets.length === 0) return []

  const urls = []
  for (const subnet of subnets) {
    for (let host = 1; host <= 254; host += 1) {
      for (const port of ports) {
        urls.push(`http://${subnet}.${host}:${port}/api/health`)
      }
    }
  }

  const started = Date.now()
  const stats = { hit: 0, refused: 0, timeout: 0, badShape: 0, other: 0 }
  console.log(`[subnet-scan] ${urls.length} probes across subnets=${JSON.stringify(subnets)} ports=${JSON.stringify(ports)}`)

  const results = []
  let cursor = 0

  async function worker() {
    while (cursor < urls.length) {
      const i = cursor++
      const { hit, reason } = await probeHealth(urls[i], { timeoutMs, fetchImpl })
      stats[reason] = (stats[reason] || 0) + 1
      if (hit) {
        console.log(`[subnet-scan] hit ${hit.url} (${hit.name})`)
        results.push(hit)
      }
    }
  }

  const pool = Array.from({ length: Math.min(concurrency, urls.length) }, worker)
  await Promise.all(pool)

  const seen = new Set()
  const deduped = results.filter((r) => {
    if (seen.has(r.url)) return false
    seen.add(r.url)
    return true
  })
  console.log(
    `[subnet-scan] done in ${Date.now() - started}ms — ` +
    `hits=${stats.hit} refused=${stats.refused} timeout=${stats.timeout} badShape=${stats.badShape} other=${stats.other}`
  )
  return deduped
}

async function probeHealth(healthUrl, { timeoutMs, fetchImpl }) {
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null
  try {
    const res = await fetchImpl(healthUrl, controller ? { signal: controller.signal } : undefined)
    if (!res) return { hit: null, reason: 'other' }
    if (!res.ok) return { hit: null, reason: 'badShape' }
    const data = await (typeof res.json === 'function' ? res.json() : Promise.resolve(null))
    if (!data || data.status !== 'ok') return { hit: null, reason: 'badShape' }

    const probed = safeUrl(healthUrl)
    if (!probed) return { hit: null, reason: 'other' }
    const port = parseInt(probed.port, 10)
    if (!Number.isFinite(port) || port <= 0) return { hit: null, reason: 'other' }

    const base = `http://${probed.hostname}:${port}`
    return {
      hit: {
        name: data.server_name || probed.hostname,
        host: probed.hostname,
        port,
        url: base,
        version: data.version || null,
      },
      reason: 'hit',
    }
  } catch (err) {
    const msg = err?.message || ''
    if (err?.name === 'AbortError') return { hit: null, reason: 'timeout' }
    if (msg.includes('ERR_CONNECTION_REFUSED') || msg.includes('refused')) {
      return { hit: null, reason: 'refused' }
    }
    return { hit: null, reason: 'other' }
  } finally {
    if (timer) clearTimeout(timer)
  }
}

function safeUrl(str) {
  try {
    return new URL(str)
  } catch {
    return null
  }
}

/**
 * WebRTC host-candidate probe. Some browsers mDNS-mask the candidate
 * (returns `.local` instead of an IPv4); in that case we return null
 * and the caller uses fallback subnets.
 */
async function defaultRtcProbe() {
  if (typeof RTCPeerConnection === 'undefined') return null

  return new Promise((resolve) => {
    let settled = false
    const done = (val) => { if (!settled) { settled = true; resolve(val) } }

    const pc = new RTCPeerConnection({ iceServers: [] })
    try {
      pc.createDataChannel('')
    } catch {
      try { pc.close() } catch {}
      done(null)
      return
    }

    pc.onicecandidate = (evt) => {
      if (!evt.candidate) return
      const match = (evt.candidate.candidate || '').match(/ (\d+\.\d+\.\d+\.\d+) /)
      if (!match) return
      const ip = match[1]
      if (ip.startsWith('0.') || ip.startsWith('127.')) return
      done(ip)
      try { pc.close() } catch {}
    }

    pc.createOffer().then((offer) => pc.setLocalDescription(offer)).catch(() => done(null))

    setTimeout(() => {
      try { pc.close() } catch {}
      done(null)
    }, 500)
  })
}
