/**
 * Per-platform helpers that locate Caramba API servers on the LAN.
 * All return Promise<Array<{ name, host, port, url, version? }>>.
 *
 * - electronDiscover: main-process bonjour-service via preload IPC (mDNS).
 *   Fast, precise, but only usable from the Electron main process.
 * - subnetDiscover:   parallel HTTP probe of the discovery beacon port
 *   across the local /24 subnet(s). Works in Android WebView, desktop
 *   browsers on any OS — anywhere fetch works.
 *
 * `defaultDiscover` picks the right one: Electron tries mDNS first and
 * falls back to subnet scan if mDNS returns nothing; every other client
 * goes straight to subnet scan.
 */

import {
  detectLocalSubnets,
  subnetScan,
  DISCOVERY_BEACON_PORT,
} from './subnet-scan.js'

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

/**
 * Cross-platform discovery via HTTP subnet scan of the Caramba beacon.
 * Works from any runtime that has `fetch` — Android WebView, iOS, every
 * desktop browser.
 *
 * @param {object}  opts
 * @param {string}  [opts.currentUrl]   already-saved URL; its subnet is
 *                                      added to the probe list so
 *                                      non-default networks keep working
 * @param {number}  [opts.timeoutMs]
 * @param {number}  [opts.concurrency]
 */
export async function subnetDiscover({ currentUrl = null, timeoutMs, concurrency } = {}) {
  if (typeof window === 'undefined') return []
  const subnets = await detectLocalSubnets({ currentUrl })
  return subnetScan({
    subnets,
    port: DISCOVERY_BEACON_PORT,
    timeoutMs,
    concurrency,
  })
}

/**
 * Auto-pick the right discoverer for the current runtime. The returned
 * function accepts an options bag so callers can pass `currentUrl`.
 *
 * Electron: try mDNS, fall back to subnet scan if mDNS returned nothing.
 * Everything else: subnet scan only.
 */
export function defaultDiscover() {
  if (typeof window === 'undefined') return async () => []
  if (window.api?.discoverServers) {
    return async (opts) => {
      const mdns = await electronDiscover()
      if (mdns.length > 0) return mdns
      return subnetDiscover(opts)
    }
  }
  return (opts) => subnetDiscover(opts)
}
