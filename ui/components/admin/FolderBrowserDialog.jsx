import { useEffect, useState } from 'react'

export default function FolderBrowserDialog({ api, onCancel, onSubmit }) {
  const [listing, setListing] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [kind, setKind] = useState('series')

  const load = async (path) => {
    setLoading(true)
    setError(null)
    try {
      const result = await api.browseServerPath(path || '')
      setListing(result)
    } catch (err) {
      setError(err.message || 'Failed to browse')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load('')
  }, [])

  const goTo = (p) => load(p)

  const handlePick = () => {
    if (!listing?.path) return
    onSubmit({ path: listing.path, kind })
  }

  return (
    <div
      role="dialog"
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0,0,0,0.7)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 200,
      }}
      onClick={onCancel}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: '#1a1a1a',
          color: '#fff',
          padding: 24,
          borderRadius: 12,
          minWidth: 540,
          maxWidth: '80vw',
          maxHeight: '80vh',
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        <h2 style={{ marginTop: 0 }}>Pick a folder</h2>

        <div style={{ marginBottom: 12, fontFamily: 'monospace', fontSize: 13 }}>
          {listing?.path || '(mount points)'}
          {listing?.parent != null && (
            <button
              type="button"
              style={{ marginLeft: 12, background: 'transparent', border: '1px solid #555', color: '#ccc', padding: '2px 8px', borderRadius: 4, cursor: 'pointer' }}
              onClick={() => goTo(listing.parent)}
            >
              ↑ Parent
            </button>
          )}
        </div>

        {error && <div className="alert" style={{ marginBottom: 12 }}>{error}</div>}

        <div style={{ overflowY: 'auto', flex: 1, border: '1px solid rgba(255,255,255,0.1)', borderRadius: 6 }}>
          {loading ? (
            <div style={{ padding: 16, color: '#888' }}>Loading…</div>
          ) : (
            <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>
              {(listing?.mounts?.length ? listing.mounts : listing?.entries || []).map((entry) => (
                <li
                  key={entry.path}
                  onClick={() => goTo(entry.path)}
                  style={{
                    padding: '8px 12px',
                    cursor: 'pointer',
                    borderBottom: '1px solid rgba(255,255,255,0.05)',
                  }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'rgba(255,255,255,0.06)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = 'transparent')}
                >
                  <span style={{ marginRight: 8 }}>📁</span>
                  {entry.name}
                </li>
              ))}
              {!loading && listing?.entries?.length === 0 && !listing?.mounts?.length && (
                <li style={{ padding: 16, color: '#888' }}>(empty)</li>
              )}
            </ul>
          )}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 16 }}>
          <label style={{ fontSize: 13 }}>Kind:</label>
          <select value={kind} onChange={(e) => setKind(e.target.value)} style={{ padding: '4px 8px' }}>
            <option value="series">Series</option>
            <option value="movies">Movies</option>
          </select>
          <div style={{ flex: 1 }} />
          <button type="button" onClick={onCancel} style={{ padding: '6px 12px' }}>
            Cancel
          </button>
          <button
            type="button"
            className="btn-choose-folder"
            disabled={!listing?.path}
            onClick={handlePick}
          >
            Use this folder
          </button>
        </div>
      </div>
    </div>
  )
}
