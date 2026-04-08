import { useState, useEffect, useCallback } from 'react'
import Navbar from '../components/Navbar'

export default function Settings() {
  const [syncFolder, setSyncFolder] = useState('')
  const [pathInput, setPathInput] = useState('')
  const [status, setStatus] = useState(null)
  const [message, setMessage] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(true)

  const loadData = useCallback(async () => {
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
  }, [])

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

  if (loading) return (
    <>
      <Navbar active="Settings" />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  const isEnabled = !!syncFolder
  const folderInaccessible = isEnabled && status && !status.folder_accessible

  return (
    <>
      <Navbar active="Settings" />
      <main className="settings-main">
        <h1 className="page-title">Settings</h1>

        {message && <div className="alert alert--success">{message}</div>}
        {error && <div className="alert">{error}</div>}

        {/* Sync Folder Section */}
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

        {/* Sync Status */}
        {isEnabled && status && (
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
