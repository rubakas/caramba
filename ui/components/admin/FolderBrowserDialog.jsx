import { useEffect, useState } from 'react'

export default function FolderBrowserDialog({ api, onCancel, onSubmit }) {
  const [listing, setListing] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [kind, setKind] = useState('shows')

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
          color: 'var(--text-primary, #fff)',
          padding: 24,
          borderRadius: 12,
          minWidth: 540,
          maxWidth: '80vw',
          maxHeight: '80vh',
          display: 'flex',
          flexDirection: 'column',
          border: '1px solid rgba(255,255,255,0.08)',
        }}
      >
        <h2 style={{ marginTop: 0 }}>Pick a folder</h2>

        <div style={{ marginBottom: 12, fontFamily: 'monospace', fontSize: 13, display: 'flex', alignItems: 'center', gap: 12 }}>
          <span style={{ color: 'var(--text-secondary, #ccc)' }}>{listing?.path || '(mount points)'}</span>
          {listing?.parent != null && (
            <button
              type="button"
              className="topnav-btn"
              onClick={() => goTo(listing.parent)}
            >
              ↑ Parent
            </button>
          )}
        </div>

        {error && <div className="alert" style={{ marginBottom: 12 }}>{error}</div>}

        <div style={{ overflowY: 'auto', flex: 1, border: '1px solid rgba(255,255,255,0.1)', borderRadius: 8 }}>
          {loading ? (
            <div style={{ padding: 16, color: 'var(--text-tertiary, #888)' }}>Loading…</div>
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
                <li style={{ padding: 16, color: 'var(--text-tertiary, #888)' }}>(empty)</li>
              )}
            </ul>
          )}
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 16 }}>
          <label htmlFor="folder-kind" style={{ fontSize: 13, color: 'var(--text-secondary, #ccc)' }}>Kind:</label>
          <select
            id="folder-kind"
            value={kind}
            onChange={(e) => setKind(e.target.value)}
            style={{
              padding: '6px 12px',
              background: 'rgba(255,255,255,0.06)',
              color: 'var(--text-primary, #fff)',
              border: '1px solid rgba(255,255,255,0.18)',
              borderRadius: 8,
              fontSize: 14,
              fontFamily: 'inherit',
              appearance: 'none',
              backgroundImage: "url(\"data:image/svg+xml;charset=US-ASCII,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='8' viewBox='0 0 12 8'%3E%3Cpath fill='%23999' d='M6 8L0 0h12z'/%3E%3C/svg%3E\")",
              backgroundRepeat: 'no-repeat',
              backgroundPosition: 'right 12px center',
              backgroundSize: '10px 6px',
              paddingRight: 32,
              cursor: 'pointer',
            }}
          >
            <option value="shows" style={{ background: '#1a1a1a', color: '#fff' }}>Shows</option>
            <option value="movies" style={{ background: '#1a1a1a', color: '#fff' }}>Movies</option>
          </select>
          <div style={{ flex: 1 }} />
          <button type="button" className="topnav-btn" onClick={onCancel}>
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
