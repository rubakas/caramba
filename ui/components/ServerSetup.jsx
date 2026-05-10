import { useCallback, useMemo, useState } from 'react'
import ServerDiscovery from './ServerDiscovery'
import { defaultDiscover } from '../lib/discovery'

/**
 * First-run / disconnected screen for the desktop app. Lets the user pick a
 * Caramba server (mDNS + subnet scan) or enter one manually. Calls onConnected
 * with the validated server URL once `/api/health` returns 200.
 */
export default function ServerSetup({
  initialUrl = '',
  onConnected,
  reason = null,   // optional message: "Server unreachable", "First launch", etc.
  discoverImpl,    // injectable for tests
}) {
  const discover = useMemo(() => discoverImpl || defaultDiscover(), [discoverImpl])
  const discoverFn = useCallback(
    () => discover({ currentUrl: initialUrl || null }),
    [discover, initialUrl]
  )
  const [manualUrl, setManualUrl] = useState(initialUrl || '')
  const [checking, setChecking] = useState(false)
  const [error, setError] = useState(null)

  const tryUrl = useCallback(async (url) => {
    setChecking(true)
    setError(null)
    try {
      const trimmed = url.trim().replace(/\/+$/, '')
      if (!trimmed) {
        setError('Server URL cannot be empty.')
        return
      }
      try { new URL(trimmed) } catch {
        setError('Use a full URL, e.g. http://192.168.1.10:3001')
        return
      }
      const res = await fetch(`${trimmed}/api/health`, { signal: AbortSignal.timeout(5000) })
      if (!res.ok) {
        setError(`Server replied ${res.status}`)
        return
      }
      const json = await res.json().catch(() => ({}))
      if (json?.status !== 'ok') {
        setError('Server is not healthy.')
        return
      }
      onConnected?.(trimmed)
    } catch (err) {
      setError(err?.message || 'Could not reach the server.')
    } finally {
      setChecking(false)
    }
  }, [onConnected])

  const handleManualSubmit = (e) => {
    e.preventDefault()
    tryUrl(manualUrl)
  }

  return (
    <div className="server-setup">
      <div className="server-setup-card">
        <h1 className="server-setup-title">Connect to your Caramba server</h1>
        <p className="server-setup-sub">
          {reason || 'Caramba desktop talks to a Rails server over your network. Pick one below or enter a URL.'}
        </p>

        <ServerDiscovery
          discover={discoverFn}
          onSelect={(url) => tryUrl(url)}
          currentUrl={initialUrl || null}
          connected={null}
          manualFallback={
            <form onSubmit={handleManualSubmit} className="server-setup-manual">
              <input
                type="url"
                className="api-mode-url-input"
                value={manualUrl}
                onChange={e => setManualUrl(e.target.value)}
                placeholder="http://192.168.1.10:3001"
                spellCheck={false}
                disabled={checking}
              />
              <button type="submit" className="btn-primary" disabled={checking}>
                {checking ? 'Connecting…' : 'Connect'}
              </button>
            </form>
          }
        />

        {error && <div className="alert" style={{ marginTop: 16 }}>{error}</div>}
      </div>
    </div>
  )
}
