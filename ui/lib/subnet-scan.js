/**
 * Subnet HTTP scanner — the discovery path for clients that can't do
 * mDNS (Android TV WebView, browsers on any OS).
 *
 * Design: Rails exposes a tiny TCP beacon on a fixed well-known port
 * (DISCOVERY_BEACON_PORT, default 3999). The beacon's JSON response
 * tells the client the real Rails URL, server name, and version. This
 * means the client only has to probe one port per IP — the main Rails
 * port can be anything.
 *
 * Everything here is a pure function; `fetchImpl` and the WebRTC probe
 * are injected so `node --test` can drive the code without a real
 * network or browser.
 */

export const DISCOVERY_BEACON_PORT = 3999

/**
 * Default fallback subnets when we can't determine the local one from
 * WebRTC and there's no saved URL to learn from. Covers common home-
 * router defaults plus the Android emulator's virtual LAN (10.0.2.x;
 * the host is reachable at 10.0.2.2). If none of these match, the user
 * enters a URL manually and subsequent scans learn from `currentUrl`.
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
 * Determine the local /24 subnets worth scanning. Strategy:
 *   1. Try the WebRTC host-candidate trick to learn this device's LAN IP.
 *   2. If a `currentUrl` is already saved, derive its subnet too — keeps
 *      non-default networks working once the user has connected once.
 *   3. Union with DEFAULT_FALLBACK_SUBNETS as a safety net.
 *
 * Returns a de-duplicated array of `/24` prefixes (e.g. "192.168.1").
 */
export async function detectLocalSubnets({
  currentUrl = null,
  rtc = defaultRtcProbe,
  fallbacks = DEFAULT_FALLBACK_SUBNETS,
} = {}) {
  const subnets = new Set()

  try {
    const ip = await rtc()
    const subnet = ipToSubnet(ip)
    if (subnet) subnets.add(subnet)
  } catch {
    // Browsers may mDNS-obfuscate the candidate or disable WebRTC entirely;
    // fall through to currentUrl + fallbacks.
  }

  if (currentUrl) {
    try {
      const u = new URL(currentUrl)
      const subnet = ipToSubnet(u.hostname)
      if (subnet) subnets.add(subnet)
    } catch {
      // currentUrl not parseable; ignore.
    }
  }

  for (const f of fallbacks) subnets.add(f)

  return Array.from(subnets)
}

/**
 * Parallel scan of `<subnet>.<1..254>:<port>` with bounded concurrency.
 * Each probe expects the beacon's JSON shape:
 *   { status: "ok", url, server_name, version }
 * Returns a de-duplicated list of { name, host, port, url, version }.
 *
 * - `port` defaults to DISCOVERY_BEACON_PORT. The *returned* `port` is
 *   the one the beacon reports (i.e. the real Rails port), not the
 *   beacon's own port.
 * - `timeoutMs` is per-probe; hangers are dropped and don't block the
 *   batch.
 * - `concurrency` caps in-flight probes so mobile WebViews don't exhaust
 *   their socket quota.
 * - `fetchImpl` is injected for tests.
 */
export async function subnetScan({
  subnets,
  port = DISCOVERY_BEACON_PORT,
  timeoutMs = 800,
  concurrency = 64,
  fetchImpl = (typeof fetch !== 'undefined' ? fetch : null),
} = {}) {
  if (!fetchImpl) return []
  if (!Array.isArray(subnets) || subnets.length === 0) return []

  // Build the full URL list up front. Host byte 0 and 255 are network /
  // broadcast, skip them.
  const urls = []
  for (const subnet of subnets) {
    for (let host = 1; host <= 254; host += 1) {
      urls.push(`http://${subnet}.${host}:${port}/`)
    }
  }

  const results = []
  let cursor = 0

  async function worker() {
    while (true) {
      const i = cursor
      cursor += 1
      if (i >= urls.length) return
      const url = urls[i]
      const hit = await probeBeacon(url, { timeoutMs, fetchImpl })
      if (hit) results.push(hit)
    }
  }

  const pool = Array.from({ length: Math.min(concurrency, urls.length) }, worker)
  await Promise.all(pool)

  // De-dup by reported URL — a beacon can reply from multiple interfaces.
  const seen = new Set()
  return results.filter((r) => {
    if (seen.has(r.url)) return false
    seen.add(r.url)
    return true
  })
}

async function probeBeacon(beaconUrl, { timeoutMs, fetchImpl }) {
  const controller = typeof AbortController !== 'undefined' ? new AbortController() : null
  const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null
  try {
    const res = await fetchImpl(beaconUrl, controller ? { signal: controller.signal } : undefined)
    if (!res || !res.ok) return null
    const data = await (typeof res.json === 'function' ? res.json() : Promise.resolve(null))
    if (!data || data.status !== 'ok') return null
    const appPort = typeof data.port === 'number' ? data.port : parseInt(data.port, 10)
    if (!Number.isFinite(appPort) || appPort <= 0) return null

    // The beacon reports only `port`; we build the URL around the host we
    // reached the beacon on. A server's own IP is often unreachable from
    // the client (Android emulator NAT hits the host via 10.0.2.2, not
    // the host's 192.168.x) — the beacon's own host is the one that works.
    const probedHost = safeUrl(beaconUrl)?.hostname
    if (!probedHost) return null

    return {
      name: data.server_name || probedHost,
      host: probedHost,
      port: appPort,
      url: `http://${probedHost}:${appPort}`,
      version: data.version || null,
    }
  } catch {
    return null
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
 * Default WebRTC host-candidate probe. Creates a throwaway
 * RTCPeerConnection, triggers ICE gathering with no TURN/STUN servers,
 * reads the first non-mDNS-masked IPv4 from the candidate string.
 *
 * Returns null if WebRTC isn't available or if the browser only emits
 * `.local` mDNS candidates (modern Chrome + strict privacy mode).
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
      const cand = evt.candidate.candidate || ''
      const match = cand.match(/ (\d+\.\d+\.\d+\.\d+) /)
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
