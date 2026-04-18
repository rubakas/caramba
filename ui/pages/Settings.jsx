import { useState, useEffect, useCallback } from 'react'
import Navbar from '../components/Navbar'

export default function Settings({ apiMode, apiConnected, onApiModeChange, isWebMode, onApiUrlChange, apiUrl, hideNavbar = false }) {
  const [syncFolder, setSyncFolder] = useState('')
  const [pathInput, setPathInput] = useState('')
  const [status, setStatus] = useState(null)
  const [message, setMessage] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(true)

  // API mode local state (desktop)
  const [serverUrlInput, setServerUrlInput] = useState(apiMode?.server_url || '')
  const [localPlaybackOn, setLocalPlaybackOn] = useState(apiMode?.local_playback !== false)
  const [apiSaving, setApiSaving] = useState(false)

  // Android TV API URL state
  const [androidApiUrlInput, setAndroidApiUrlInput] = useState(apiUrl || 'http://localhost:3001')
  const [androidApiSaving, setAndroidApiSaving] = useState(false)

  // Force transcode toggle (all modes) — per-device, persisted in localStorage
  const [forceTranscode, setForceTranscode] = useState(() => {
    try { return typeof window !== 'undefined' && window.localStorage?.getItem('caramba.forceTranscode') === 'true' } catch { return false }
  })

  // Sync serverUrlInput when apiMode prop changes (e.g. initial load)
  useEffect(() => {
    if (apiMode?.server_url != null) {
      setServerUrlInput(apiMode.server_url || '')
    }
  }, [apiMode?.server_url])

  // Sync localPlaybackOn when apiMode prop changes
  useEffect(() => {
    setLocalPlaybackOn(apiMode?.local_playback !== false)
  }, [apiMode?.local_playback])

  // Sync Android TV API URL input
  useEffect(() => {
    if (apiUrl) {
      setAndroidApiUrlInput(apiUrl)
    }
  }, [apiUrl])

  const loadData = useCallback(async () => {
    // In web mode or Android TV, window.api doesn't exist - skip loading desktop settings
    if (isWebMode || !window.api?.getSettings) {
      setLoading(false)
      return
    }
    try {
      const settings = await window.api.getSettings()
      const folder = settings.sync_folder || ''
      setSyncFolder(folder)
      setPathInput(folder)
      setStatus(settings.status || null)
    } catch (err) {
      console.error('Failed to load settings:', err)
    } finally {
      setLoading(false)
    }
  }, [isWebMode])

  useEffect(() => {
    loadData()
  }, [loadData])

  const showToast = (msg, isError = false) => {
    if (isError) {
      setError(msg)
      setMessage(null)
    } else {
      setMessage(msg)
      setError(null)
    }
    setTimeout(() => { setMessage(null); setError(null) }, 4000)
  }

  const saveSyncFolder = async (folder) => {
    setSyncFolder(folder)
    setPathInput(folder)
    const result = await window.api.setSyncFolder(folder)
    if (result.error) {
      showToast(result.error, true)
    } else {
      showToast(result.message)
      loadData()
    }
  }

  const handleChooseFolder = async () => {
    const path = await window.api.selectFolder()
    if (!path) return
    await saveSyncFolder(path)
  }

  const handlePathSubmit = async (e) => {
    e.preventDefault()
    const trimmed = pathInput.trim()
    if (!trimmed) return
    if (trimmed === syncFolder) return
    await saveSyncFolder(trimmed)
  }

  const handleDisable = async () => {
    const result = await window.api.setSyncFolder(null)
    setSyncFolder('')
    setPathInput('')
    if (result.error) {
      showToast(result.error, true)
    } else {
      showToast(result.message)
      loadData()
    }
  }

  const handleSyncNow = async () => {
    const result = await window.api.syncNow()
    if (result.error) {
      showToast(result.error, true)
    } else {
      showToast(result.message)
      loadData()
    }
  }

  const handleLoadFromSync = async () => {
    if (!confirm('This will replace your local database with the copy from the sync folder. Continue?')) return
    const result = await window.api.loadFromSync()
    if (result.error) {
      showToast(result.error, true)
    } else {
      showToast(result.message)
      loadData()
    }
  }

  // --- API Mode handlers (desktop) ---

  const handleApiToggle = async () => {
    if (!window.api?.setApiMode) return
    const newEnabled = !apiMode?.enabled
    setApiSaving(true)
    try {
      const result = await window.api.setApiMode({ enabled: newEnabled })
      if (result.error) {
        showToast(result.error, true)
      } else {
        onApiModeChange?.({ enabled: result.enabled, server_url: result.server_url, local_playback: result.local_playback })
        showToast(newEnabled ? 'API mode enabled.' : 'API mode disabled.')
      }
    } catch (err) {
      showToast('Failed to update API mode.', true)
    } finally {
      setApiSaving(false)
    }
  }

  const handleLocalPlaybackToggle = async () => {
    if (!window.api?.setApiMode) return
    const newValue = !localPlaybackOn
    // Flip the switch immediately for responsiveness
    setLocalPlaybackOn(newValue)
    setApiSaving(true)
    try {
      const result = await window.api.setApiMode({ localPlayback: newValue })
      if (result.error) {
        // Revert on error
        setLocalPlaybackOn(!newValue)
        showToast(result.error, true)
      } else {
        onApiModeChange?.({
          enabled: result.enabled,
          server_url: result.server_url,
          local_playback: result.local_playback,
        })
        showToast(newValue ? 'Local playback enabled.' : 'Local playback disabled — will stream from server.')
      }
    } catch (err) {
      setLocalPlaybackOn(!newValue)
      showToast('Failed to update playback setting.', true)
    } finally {
      setApiSaving(false)
    }
  }

  const handleServerUrlSubmit = async (e) => {
    e.preventDefault()
    if (!window.api?.setApiMode) return
    const trimmed = serverUrlInput.trim()
    if (trimmed === (apiMode?.server_url || '')) return
    setApiSaving(true)
    try {
      const result = await window.api.setApiMode({ serverUrl: trimmed || null })
      if (result.error) {
        showToast(result.error, true)
      } else {
        onApiModeChange?.({ enabled: result.enabled, server_url: result.server_url, local_playback: result.local_playback })
        showToast(trimmed ? 'Server URL saved.' : 'Server URL cleared.')
      }
    } catch (err) {
      showToast('Failed to save server URL.', true)
    } finally {
      setApiSaving(false)
    }
  }

  // --- Android TV API URL handler ---

  const handleAndroidApiUrlSubmit = async (e) => {
    if (e) e.preventDefault()
    const trimmed = androidApiUrlInput.trim()
    if (!trimmed) {
      showToast('API URL cannot be empty.', true)
      return
    }

    // Skip if URL hasn't changed (but allow explicit save button clicks)
    if (trimmed === apiUrl && e?.type !== 'click') return

    console.log('[Settings] Saving Android API URL:', trimmed)
    setAndroidApiSaving(true)
    try {
      // Validate URL format
      new URL(trimmed)

      console.log('[Settings] Calling onApiUrlChange callback...')
      const success = await onApiUrlChange?.(trimmed)
      console.log('[Settings] onApiUrlChange result:', success)

      if (success) {
        showToast('Server URL saved. Reloading...')
        // App.jsx will handle the reload, but add fallback
        setTimeout(() => {
          console.log('[Settings] Fallback reload triggered')
          window.location.reload()
        }, 1000)
      } else {
        showToast('Failed to save server URL.', true)
      }
    } catch (err) {
      console.error('[Settings] Error saving URL:', err)
      showToast('Invalid URL format. Use http://192.168.1.100:3001', true)
    } finally {
      setAndroidApiSaving(false)
    }
  }

  const handleForceTranscodeToggle = () => {
    const next = !forceTranscode
    setForceTranscode(next)
    try { window.localStorage.setItem('caramba.forceTranscode', next ? 'true' : 'false') } catch {}
    showToast(next ? 'Always transcode enabled. Applies on next playback.' : 'Always transcode disabled. Applies on next playback.')
  }

  // Detect if this is Android TV mode
  const isAndroidTvMode = !!onApiUrlChange

  if (loading) return (
    <>
      {!hideNavbar && <Navbar active="Settings" />}
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  const isEnabled = !!syncFolder
  const folderInaccessible = isEnabled && status && !status.folder_accessible
  const hasApiMode = !!onApiModeChange // Only show API mode section in desktop

  return (
    <>
      {!hideNavbar && <Navbar active="Settings" />}
      <main className="settings-main">
        <h1 className="page-title">Settings</h1>

        {message && <div className="alert alert--success">{message}</div>}
        {error && <div className="alert">{error}</div>}

        {/* Playback Section — all modes */}
        <section className="settings-section">
          <h2 className="settings-section-title">Playback</h2>
          <p className="settings-help">
            Force video to be re-encoded to H.264 for maximum compatibility.
            Enable this if you see buffering or audio/video sync issues on some files.
            Uses more CPU on the server.
          </p>

          <div className="settings-form">
            <div className="api-mode-toggle" style={{ marginBottom: 0 }}>
              <span className="api-mode-toggle-label">Always transcode video</span>
              <label className="toggle-switch">
                <input
                  type="checkbox"
                  checked={forceTranscode}
                  onChange={handleForceTranscodeToggle}
                />
                <span className="toggle-switch-track" />
                <span className="toggle-switch-thumb" />
              </label>
            </div>
          </div>
        </section>

            {/* Android TV API URL Section */}
        {isAndroidTvMode && (
          <section className="settings-section">
            <h2 className="settings-section-title">Server Configuration</h2>
            <p className="settings-help">
              Configure the Caramba server URL that this TV will connect to.
              Use http://IP:3000 format for local network servers.
            </p>

            <div className="settings-form">
              <div className="field">
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
              </div>
            </div>

            <p className="settings-hint" style={{ marginTop: '16px' }}>
              Example: http://192.168.1.100:3000 or http://nas.local:3000
            </p>

            {apiUrl && (
              <p className="settings-hint" style={{ marginTop: '8px', color: 'var(--text-secondary)' }}>
                Current: {apiUrl}
              </p>
            )}
          </section>
        )}


        {/* API Mode Section — desktop only */}
        {hasApiMode && !isWebMode && (
          <section className="settings-section">
            <h2 className="settings-section-title">API Mode</h2>
            <p className="settings-help">
              Connect to a Caramba server to share your library across devices.
              Data operations will use the API when reachable, with automatic fallback to local database.
            </p>

            <div className="settings-form">
              <div className="api-mode-toggle">
                <span className="api-mode-toggle-label">Enable API Mode</span>
                <label className="toggle-switch">
                  <input
                    type="checkbox"
                    checked={!!apiMode?.enabled}
                    onChange={handleApiToggle}
                    disabled={apiSaving || !apiMode?.server_url}
                  />
                  <span className="toggle-switch-track" />
                  <span className="toggle-switch-thumb" />
                </label>
              </div>

              <div className="field">
                <div className="api-mode-url-row">
                  {apiMode?.enabled && (
                    <span className={`api-mode-status ${apiConnected ? 'api-mode-status--connected' : 'api-mode-status--disconnected'}`}>
                      <span className="api-mode-status-dot" />
                      {apiConnected ? 'Connected' : 'Disconnected'}
                    </span>
                  )}
                  <form onSubmit={handleServerUrlSubmit} style={{ flex: 1 }}>
                    <input
                      type="text"
                      className="api-mode-url-input"
                      value={serverUrlInput}
                      onChange={e => setServerUrlInput(e.target.value)}
                      onBlur={handleServerUrlSubmit}
                      placeholder="http://192.168.1.100:3000"
                      spellCheck={false}
                      disabled={apiSaving}
                    />
                  </form>
                </div>
              </div>

              {apiMode?.enabled && (
                <div className="api-mode-toggle" style={{ marginBottom: 0 }}>
                  <div>
                    <span className="api-mode-toggle-label">Local Playback</span>
                    <span className="settings-hint" style={{ display: 'block', marginTop: 2 }}>
                      {localPlaybackOn
                        ? 'Uses local transcoder when file is accessible'
                        : 'Always streams from server'}
                    </span>
                  </div>
                  <label className="toggle-switch">
                    <input
                      type="checkbox"
                      checked={localPlaybackOn}
                      onChange={handleLocalPlaybackToggle}
                      disabled={apiSaving}
                    />
                    <span className="toggle-switch-track" />
                    <span className="toggle-switch-thumb" />
                  </label>
                </div>
              )}
            </div>
          </section>
        )}

        {/* Sync Folder Section — desktop only */}
        {!isWebMode && !isAndroidTvMode && (
          <section className="settings-section">
            <h2 className="settings-section-title">Database Sync</h2>
            <p className="settings-help">
              Choose a shared folder (Dropbox, iCloud, NAS, etc.) to sync your database between machines.
              For network shares, paste the local mount path directly.
            </p>
            <div className="settings-form">
              <div className="field">
                <form className="folder-picker" onSubmit={handlePathSubmit}>
                  <button type="button" className="btn-choose-folder" onClick={handleChooseFolder}>
                    Browse...
                  </button>
                  <input
                    type="text"
                    className={`folder-path-input${folderInaccessible ? ' folder-path-input--error' : ''}`}
                    value={pathInput}
                    onChange={e => setPathInput(e.target.value)}
                    onBlur={handlePathSubmit}
                    placeholder="/Volumes/NAS/sync-folder"
                    spellCheck={false}
                  />
                </form>
                {folderInaccessible && (
                  <p className="settings-warning">
                    Sync folder is not accessible. If this is a network share, make sure the remote volume is mounted.
                  </p>
                )}
              </div>
              {isEnabled && (
                <div className="settings-actions">
                  <button type="button" className="btn-ghost" onClick={handleDisable}>
                    Disable Sync
                  </button>
                </div>
              )}
            </div>
          </section>
        )}

        {/* Sync Status — desktop only */}
        {!isWebMode && !isAndroidTvMode && isEnabled && status && (
          <section className="settings-section">
            <h2 className="settings-section-title">Sync Status</h2>
            <div className="sync-status-grid">
              <div className="sync-status-card">
                <span className="sync-status-label">Local Database</span>
                <span className="sync-status-value">
                  {status.local_size ? `${(status.local_size / 1024).toFixed(0)} KB` : 'Unknown'}
                </span>
                {status.local_modified && (
                  <span className="sync-status-detail">
                    Modified: {new Date(status.local_modified).toLocaleString()}
                  </span>
                )}
              </div>
              <div className="sync-status-card">
                <span className="sync-status-label">Sync Copy</span>
                {status.sync_size ? (
                  <>
                    <span className="sync-status-value">{(status.sync_size / 1024).toFixed(0)} KB</span>
                    {status.sync_modified && (
                      <span className="sync-status-detail">
                        Modified: {new Date(status.sync_modified).toLocaleString()}
                      </span>
                    )}
                  </>
                ) : (
                  <span className="sync-status-value sync-status-value--none">Not yet synced</span>
                )}
              </div>
              <div className="sync-status-card">
                <span className="sync-status-label">Last Sync</span>
                {status.last_sync ? (
                  <span className="sync-status-value">
                    {new Date(status.last_sync).toLocaleString()}
                  </span>
                ) : (
                  <span className="sync-status-value sync-status-value--none">Never</span>
                )}
              </div>
            </div>
            <div className="settings-actions">
              <button className="btn-primary" onClick={handleSyncNow}>Sync Now</button>
              <button className="btn-ghost" onClick={handleLoadFromSync}>
                Load from Sync Folder
              </button>
            </div>
            <p className="settings-hint">Database syncs automatically when you open or close the app.</p>
          </section>
        )}
      </main>
    </>
  )
}
