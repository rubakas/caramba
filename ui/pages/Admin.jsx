import { useState, useEffect, useCallback } from 'react'
import { useApi, useCapabilities } from '../context/ApiContext'
import Navbar from '../components/Navbar'
import FoldersManager from '../components/admin/FoldersManager'
import PendingMatchesQueue from '../components/admin/PendingMatchesQueue'
import RecentlyMatchedList from '../components/admin/RecentlyMatchedList'

export default function Admin() {
  const api = useApi()
  const { canAdmin } = useCapabilities()
  const [folders, setFolders] = useState([])
  const [pendingImports, setPendingImports] = useState([])
  const [confirmedImports, setConfirmedImports] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [scanning, setScanning] = useState(false)

  const refresh = useCallback(async () => {
    try {
      const [f, p, fail, c] = await Promise.all([
        api.listMediaFolders(),
        api.listPendingImports('pending'),
        api.listPendingImports('failed'),
        api.listPendingImports('confirmed', { limit: 10 }),
      ])
      setFolders(f || [])
      setPendingImports([...(fail || []), ...(p || [])])
      setConfirmedImports(c || [])
      setError(null)
    } catch (err) {
      setError(err.message || 'Failed to load admin data')
    } finally {
      setLoading(false)
    }
  }, [api])

  useEffect(() => {
    if (!canAdmin) {
      setLoading(false)
      return
    }
    refresh()
    const id = setInterval(refresh, 10000)
    return () => clearInterval(id)
  }, [canAdmin, refresh])

  const handleScanNow = useCallback(async () => {
    setScanning(true)
    setError(null)
    try {
      const result = await api.triggerAdminScan()
      await refresh()
      if (result && typeof result.created === 'number' && result.created === 0) {
        setError('Scan finished — no new entries to import.')
      }
    } catch (err) {
      setError(err.message || 'Failed to run scan')
    } finally {
      setScanning(false)
    }
  }, [api, refresh])

  if (!canAdmin) {
    return (
      <>
        <Navbar active="Admin" />
        <main className="add-main">
          <div className="add-container">
            <h1 className="page-title">Admin</h1>
            <p className="add-help">
              Admin is only available when connected to a Caramba server. Configure API mode in Settings.
            </p>
          </div>
        </main>
      </>
    )
  }

  return (
    <>
      <Navbar active="Admin" />
      <main className="add-main">
        <div className="add-container" style={{ maxWidth: 960 }}>
          <h1 className="page-title">Admin</h1>
          {error && <div className="alert">{error}</div>}
          {loading ? (
            <p className="add-help">Loading…</p>
          ) : (
            <>
              <FoldersManager
                api={api}
                folders={folders}
                onChange={refresh}
                onError={setError}
                onScanNow={handleScanNow}
                scanning={scanning}
              />
              <PendingMatchesQueue
                api={api}
                imports={pendingImports}
                onChange={refresh}
                onError={setError}
              />
              <RecentlyMatchedList
                api={api}
                imports={confirmedImports}
                onChange={refresh}
                onError={setError}
              />
            </>
          )}
        </div>
      </main>
    </>
  )
}
