/**
 * LAN discovery of Caramba API servers.
 *
 * - electronDiscover: mDNS via the Electron main-process preload
 *   (bonjour-service). Precise but only usable from Electron.
 * - subnetDiscover:   HTTP scan of `/api/health` on the default Rails
 *   ports across the local subnet(s). Works anywhere `fetch` does:
 *   browsers, Android WebView, the Electron renderer, Node.
 *
 * On Electron we run both in parallel and merge — mDNS can miss a
 * server (multicast filtering, slow responder) that the subnet scan
 * finds, and vice versa.
 */

import { detectLocalSubnets, subnetScan } from './subnet-scan.js'

/** Electron desktop — delegates to main process via preload. */
export async function electronDiscover() {
  if (!window.api?.discoverServers) return []
  try {
    const servers = await window.api.discoverServers()
    return Array.isArray(servers) ? servers : []
  } catch (err) {
    console.warn('[discovery] electronDiscover failed:', err)
    return []
  }
}

export async function subnetDiscover({ currentUrl = null, timeoutMs, concurrency } = {}) {
  if (typeof window === 'undefined') return []
  const subnets = await detectLocalSubnets({ currentUrl })
  return subnetScan({ subnets, timeoutMs, concurrency })
}

/**
 * Returned function accepts an options bag so callers can pass
 * `currentUrl`. Electron runs both paths and merges; everything else
 * runs subnet scan only.
 */
export function defaultDiscover() {
  if (typeof window === 'undefined') return async () => []
  if (window.api?.discoverServers) {
    return async (opts) => {
      const [mdns, subnet] = await Promise.all([
        electronDiscover(),
        subnetDiscover(opts),
      ])
      return dedupeBestPerServer([...mdns, ...subnet])
    }
  }
  return async (opts) => dedupeBestPerServer(await subnetDiscover(opts))
}

/**
 * Collapse entries that refer to the same server. Keys by lowercase
 * `server_name`; within each key, pick the "best" entry:
 *   1. highest port wins — direct Rails (:3001) over Vite proxy (:3000).
 *   2. on port ties, lowest IP wins — primary Wi-Fi interface (.108)
 *      over Thunderbolt/VPN aliases (.109…).
 *   3. hostnames (e.g. mDNS "nas.local") lose the IP comparison
 *      gracefully and are only overwritten on strict port wins, so a
 *      friendlier hostname beats an IP duplicate when ports match.
 *
 * Entries without a resolvable `name` key fall through as distinct
 * results (hostname used as the dedup key in that case).
 */
function dedupeBestPerServer(entries) {
  const best = new Map()
  for (const e of entries) {
    if (!e?.url) continue
    const key = (e.name || e.host || '').toLowerCase()
    if (!key) { best.set(e.url, e); continue }
    const prev = best.get(key)
    if (!prev) { best.set(key, e); continue }
    if (e.port > prev.port) { best.set(key, e); continue }
    if (e.port === prev.port && compareIp(e.host, prev.host) < 0) {
      best.set(key, e)
    }
  }
  return Array.from(best.values())
}

function compareIp(a, b) {
  const pa = parseIp(a)
  const pb = parseIp(b)
  // Hostnames (e.g. "nas.local") return NaN and always lose — so a
  // friendly hostname, once in the map, stays there.
  if (!pa) return 1
  if (!pb) return -1
  for (let i = 0; i < 4; i += 1) {
    if (pa[i] !== pb[i]) return pa[i] - pb[i]
  }
  return 0
}

function parseIp(str) {
  const m = typeof str === 'string' && str.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)
  return m ? [ +m[1], +m[2], +m[3], +m[4] ] : null
}
