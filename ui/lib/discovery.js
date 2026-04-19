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
      return dedupeByUrl([...mdns, ...subnet])
    }
  }
  return (opts) => subnetDiscover(opts)
}

function dedupeByUrl(entries) {
  const seen = new Set()
  const out = []
  for (const e of entries) {
    if (!e?.url || seen.has(e.url)) continue
    seen.add(e.url)
    out.push(e)
  }
  return out
}
