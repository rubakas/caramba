import { useState, useEffect, useCallback, useMemo } from 'react'
import Navbar from '../components/Navbar'
import ServerDiscovery from '../components/ServerDiscovery'
import { defaultDiscover } from '../lib/discovery'
import { useApi, useCapabilities } from '../context/ApiContext'

/**
 * Settings page. Shared between three runtimes:
 *   - Desktop (Electron): receives serverUrl/onChangeServer/playerEngine/onPlayerEngineChange
 *   - Web browser: receives isWebMode=true
 *   - Android TV (Capacitor): receives onApiUrlChange/apiUrl/hideNavbar
 */
export default function Settings({
  // Desktop
  serverUrl,
  onChangeServer,
  playerEngine,
  onPlayerEngineChange,
  // Android TV
  isWebMode,
  onApiUrlChange,
  apiUrl,
  hideNavbar = false,
  discover,
}) {
  const api = useApi()
  const { hasServerDiscovery, canDownload } = useCapabilities()
  const baseDiscover = useMemo(() => discover || defaultDiscover(api), [discover, api])
  const currentSavedUrl = apiUrl || serverUrl || null
  const discoverFn = useCallback(
    () => baseDiscover({ currentUrl: currentSavedUrl }),
    [baseDiscover, currentSavedUrl]
  )
  const [message, setMessage] = useState(null)
  const [error, setError] = useState(null)

  // Android TV API URL state
  const [androidApiUrlInput, setAndroidApiUrlInput] = useState(apiUrl || 'http://localhost:3001')
  const [androidApiSaving, setAndroidApiSaving] = useState(false)

  // Desktop: downloads folder (read once via adapter)
  const [downloadsFolder, setDownloadsFolder] = useState(null)
  useEffect(() => {
    if (!api.getDesktopPreferences) return
    let cancelled = false
    api.getDesktopPreferences().then(prefs => {
      if (cancelled) return
      setDownloadsFolder(prefs?.downloadsFolder || null)
    }).catch(() => {})
    return () => { cancelled = true }
  }, [api])

  useEffect(() => {
    if (apiUrl) setAndroidApiUrlInput(apiUrl)
  }, [apiUrl])

  const showToast = (msg, isError = false) => {
    if (isError) { setError(msg); setMessage(null) } else { setMessage(msg); setError(null) }
    setTimeout(() => { setMessage(null); setError(null) }, 4000)
  }

  // --- Android TV API URL handler ---
  const handleAndroidApiUrlSubmit = async (e) => {
    if (e?.preventDefault) e.preventDefault()
    const trimmed = androidApiUrlInput.trim()
    if (!trimmed) {
      showToast('API URL cannot be empty.', true)
      return
    }
    if (trimmed === apiUrl && e?.type !== 'click') return

    setAndroidApiSaving(true)
    try {
      new URL(trimmed)
      const success = await onApiUrlChange?.(trimmed)
      if (success) {
        showToast('Server URL saved. Reloading...')
        setTimeout(() => { window.location.reload() }, 1000)
      } else {
        showToast('Failed to save server URL.', true)
      }
    } catch {
      showToast('Invalid URL format. Use http://192.168.1.100:3001', true)
    } finally {
      setAndroidApiSaving(false)
    }
  }

  const handleChooseDownloadsFolder = async () => {
    if (!api.selectFolder) return
    const path = await api.selectFolder()
    if (!path) return
    try {
      await api.setDesktopPreferences?.({ downloadsFolder: path })
      setDownloadsFolder(path)
      showToast('Downloads folder updated.')
    } catch (err) {
      showToast(err?.message || 'Failed to update folder.', true)
    }
  }

  const isAndroidTvMode = !!onApiUrlChange
  const isDesktopMode = !!onChangeServer

  return (
    <>
      {!hideNavbar && <Navbar active="Settings" />}
      <main className="settings-main">
        <h1 className="page-title">Settings</h1>

        {message && <div className="alert alert--success">{message}</div>}
        {error && <div className="alert">{error}</div>}

        {/* Playback — desktop only (player engine choice) */}
        {isDesktopMode && onPlayerEngineChange && (
        <section className="settings-section">
          <h2 className="settings-section-title">Playback</h2>

          <div className="settings-form">
            <div className="field">
              <label htmlFor="player-engine" className="settings-label">Player engine</label>
              <div className="settings-select-wrap">
                <select
                  id="player-engine"
                  className="settings-select"
                  value={playerEngine || 'hlsjs'}
                  onChange={(e) => onPlayerEngineChange(e.target.value)}
                >
                  <option value="hlsjs">Browser (hls.js)</option>
                  <option value="libvlc">Embedded VLC</option>
                </select>
              </div>
              <p className="settings-hint" style={{ marginTop: 6 }}>
                Embedded VLC paints into the desktop window using libVLC. Use the browser engine for the simplest setup.
              </p>
            </div>
          </div>
        </section>
        )}

        {/* Android TV API URL */}
        {isAndroidTvMode && (
          <section className="settings-section">
            <h2 className="settings-section-title">Server Configuration</h2>
            <p className="settings-help">
              Caramba scans the local network for servers advertising themselves.
              If none are found you can enter a URL by hand.
            </p>

            <ServerDiscovery
              discover={discoverFn}
              onSelect={(url) => onApiUrlChange?.(url)}
              currentUrl={apiUrl || null}
              connected={null}
              manualFallback={
                <form onSubmit={handleAndroidApiUrlSubmit} style={{ display: 'flex', gap: '12px', alignItems: 'center' }}>
                  <input
                    type="url"
                    className="api-mode-url-input"
                    value={androidApiUrlInput}
                    onChange={e => setAndroidApiUrlInput(e.target.value)}
                    placeholder="http://192.168.1.100:3000"
                    spellCheck={false}
                    disabled={androidApiSaving}
                    style={{ flex: 1 }}
                  />
                  <button
                    type="button"
                    className="btn-primary"
                    disabled={androidApiSaving}
                    onClick={() => handleAndroidApiUrlSubmit({ type: 'click' })}
                  >
                    {androidApiSaving ? 'Saving...' : 'Save Server URL'}
                  </button>
                </form>
              }
            />
          </section>
        )}

        {/* Desktop: server URL display + change-server button */}
        {isDesktopMode && (
          <section className="settings-section">
            <h2 className="settings-section-title">Server</h2>
            <p className="settings-help">
              Caramba desktop talks to a Rails server over your network.
              Switch servers if you move to a different network or run multiple libraries.
            </p>
            <div className="settings-form">
              <div className="discovery-current">
                <div className="discovery-current-main">
                  <div className="discovery-current-label">Connected to</div>
                  <div className="discovery-current-url">{serverUrl || '—'}</div>
                </div>
                <button type="button" className="btn-ghost" onClick={onChangeServer}>
                  Change server
                </button>
              </div>
            </div>
          </section>
        )}

        {/* Desktop: downloads folder */}
        {isDesktopMode && canDownload && (
          <section className="settings-section">
            <h2 className="settings-section-title">Downloads</h2>
            <p className="settings-help">
              Folder where Caramba saves downloaded episodes and movies.
            </p>
            <div className="settings-form">
              <div className="folder-picker">
                <button type="button" className="btn-choose-folder" onClick={handleChooseDownloadsFolder}>
                  Browse...
                </button>
                <input
                  type="text"
                  className="folder-path-input"
                  value={downloadsFolder || ''}
                  readOnly
                  placeholder="Default downloads folder"
                  spellCheck={false}
                />
              </div>
            </div>
          </section>
        )}
      </main>
    </>
  )
}
