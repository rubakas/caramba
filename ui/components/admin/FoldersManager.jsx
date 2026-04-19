import { useState } from 'react'
import FolderBrowserDialog from './FolderBrowserDialog'

export default function FoldersManager({ api, folders, onChange, onError, onScanNow, scanning }) {
  const [picking, setPicking] = useState(false)

  const handleAdd = async ({ path, kind }) => {
    setPicking(false)
    try {
      await api.addMediaFolder({ path, kind })
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to add folder')
    }
  }

  const handleRemove = async (folder) => {
    if (!window.confirm(`Stop tracking ${folder.path}? Existing shows/movies are kept.`)) return
    try {
      await api.removeMediaFolder(folder.id)
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to remove folder')
    }
  }

  return (
    <section style={{ marginTop: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <h2 style={{ margin: 0, fontSize: 20 }}>Media folders</h2>
        <div style={{ marginLeft: 'auto', display: 'flex', gap: 8 }}>
          <button
            type="button"
            className="btn-choose-folder"
            onClick={() => setPicking(true)}
            disabled={scanning}
          >
            + Add folder
          </button>
          <button
            type="button"
            className="btn-choose-folder"
            onClick={onScanNow}
            disabled={scanning}
          >
            {scanning ? 'Scanning…' : 'Scan now'}
          </button>
        </div>
      </div>
      {folders.length === 0 ? (
        <p className="add-help" style={{ marginTop: 12 }}>
          No folders yet. Add one to start auto-discovering media.
        </p>
      ) : (
        <table style={{ width: '100%', marginTop: 12, borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ textAlign: 'left', fontSize: 12, color: 'var(--text-tertiary, #888)' }}>
              <th style={{ padding: '8px 4px' }}>Path</th>
              <th style={{ padding: '8px 4px' }}>Kind</th>
              <th style={{ padding: '8px 4px' }}>Last scanned</th>
              <th style={{ padding: '8px 4px' }}></th>
            </tr>
          </thead>
          <tbody>
            {folders.map((f) => (
              <tr key={f.id} style={{ borderTop: '1px solid rgba(255,255,255,0.08)' }}>
                <td style={{ padding: '10px 4px', fontFamily: 'monospace' }}>{f.path}</td>
                <td style={{ padding: '10px 4px' }}>{f.kind}</td>
                <td style={{ padding: '10px 4px', color: 'var(--text-tertiary, #888)', fontSize: 12 }}>
                  {f.lastScannedAt ? new Date(f.lastScannedAt).toLocaleString() : 'never'}
                </td>
                <td style={{ padding: '10px 4px', textAlign: 'right' }}>
                  <button
                    type="button"
                    className="topnav-btn topnav-btn--danger"
                    onClick={() => handleRemove(f)}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {picking && (
        <FolderBrowserDialog
          api={api}
          onCancel={() => setPicking(false)}
          onSubmit={handleAdd}
        />
      )}
    </section>
  )
}
