import { useState, useEffect, useCallback } from 'react'

/**
 * Local-network discovery picker for the Caramba API server.
 *
 * Props:
 *   discover       async () => Array<{ name, host, port, url, version? }>
 *   onSelect       (url, entry) => void | Promise<void>
 *   manualFallback ReactNode rendered under the picker for manual entry
 *   currentUrl     string | null  — the URL already saved in settings
 *   connected      boolean | null — known connection state for currentUrl
 *                                   (null = unknown, true = healthy,
 *                                   false = known broken)
 *
 * Behaviour:
 *   - On mount, auto-scan ONLY when currentUrl is empty OR connected===false.
 *     If the user is already connected, we stay quiet.
 *   - "Scan" button always scans, from any state.
 *   - ≥1 results → list; user picks. 0 results → manualFallback + rescan.
 *   - Current server (if any) is always shown at the top so it's obvious
 *     which one you're talking to.
 */
export default function ServerDiscovery({
  discover,
  onSelect,
  manualFallback,
  currentUrl = null,
  connected = null,
}) {
  const shouldAutoScan = !currentUrl || connected === false
  const [state, setState] = useState(
    shouldAutoScan ? { status: 'scanning', servers: [] } : { status: 'idle', servers: [] }
  )
  const [picking, setPicking] = useState(null)
  const [showManual, setShowManual] = useState(false)

  const scan = useCallback(async () => {
    setState({ status: 'scanning', servers: [] })
    setShowManual(false)
    try {
      const servers = await discover()
      setState({ status: 'done', servers: servers || [] })
    } catch (err) {
      console.warn('[ServerDiscovery] scan failed:', err)
      setState({ status: 'error', servers: [], error: err?.message || 'Discovery failed' })
    }
  }, [discover])

  useEffect(() => {
    if (shouldAutoScan) scan()
    // Only run on mount / when the "connected" assumption flips
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shouldAutoScan])

  const pick = async (entry) => {
    setPicking(entry.url)
    try {
      await onSelect(entry.url, entry)
    } finally {
      setPicking(null)
    }
  }

  // "Current server" header — always shown when a URL is saved.
  const currentHeader = currentUrl ? (
    <div className={`discovery-current ${connected === false ? 'discovery-current--down' : connected ? 'discovery-current--up' : ''}`}>
      <div className="discovery-current-main">
        <div className="discovery-current-label">
          {connected === false ? 'Saved (disconnected)' : connected ? 'Connected to' : 'Saved server'}
        </div>
        <div className="discovery-current-url">{currentUrl}</div>
      </div>
      <button type="button" className="discovery-rescan" onClick={scan}>
        {state.status === 'scanning' ? 'Scanning…' : 'Scan for servers'}
      </button>
    </div>
  ) : null

  // --- Body renders below the header, depending on scan state -------

  let body = null

  if (state.status === 'scanning') {
    body = (
      <div className="discovery-status">
        <span className="discovery-spinner" aria-hidden />
        Looking for servers on your network…
      </div>
    )
  } else if (state.status === 'done' && state.servers.length >= 1) {
    body = (
      <>
        <div className="discovery-header">
          <span>Found {state.servers.length} server{state.servers.length === 1 ? '' : 's'}</span>
          <button type="button" className="discovery-rescan" onClick={scan}>Rescan</button>
        </div>
        <ul className="discovery-list">
          {state.servers.map(s => {
            const isCurrent = currentUrl && s.url === currentUrl
            return (
              <li key={s.url} className={`discovery-item${isCurrent ? ' discovery-item--current' : ''}`}>
                <div className="discovery-item-main">
                  <div className="discovery-item-name">
                    {s.name}
                    {isCurrent && <span className="discovery-item-badge">Current</span>}
                  </div>
                  <div className="discovery-item-meta">{s.host}:{s.port}{s.version ? ` · ${s.version}` : ''}</div>
                </div>
                {!isCurrent && (
                  <button
                    type="button"
                    className="btn-primary discovery-item-btn"
                    onClick={() => pick(s)}
                    disabled={picking === s.url}
                  >
                    {picking === s.url ? 'Connecting…' : 'Use this'}
                  </button>
                )}
              </li>
            )
          })}
        </ul>
        <button type="button" className="discovery-manual-toggle" onClick={() => setShowManual(v => !v)}>
          {showManual ? 'Hide manual entry' : 'Enter manually'}
        </button>
        {showManual && <div className="discovery-manual">{manualFallback}</div>}
      </>
    )
  } else if (state.status === 'done' || state.status === 'error') {
    // 0 servers, or error
    body = (
      <>
        <div className="discovery-status discovery-status--empty">
          {state.status === 'error'
            ? `Discovery failed: ${state.error}`
            : 'No servers found on your network.'}
          {' '}
          <button type="button" className="discovery-rescan-inline" onClick={scan}>Rescan</button>
        </div>
        <p className="discovery-status-hint">
          Tried your Wi-Fi's local subnet. If the server is on a different
          subnet or behind a VPN, enter its URL manually below.
        </p>
        <div className="discovery-manual">{manualFallback}</div>
      </>
    )
  }
  // state.status === 'idle' → render only currentHeader; body stays null.

  return (
    <div className="discovery">
      {currentHeader}
      {body}
    </div>
  )
}
