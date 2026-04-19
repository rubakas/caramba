import { useState } from 'react'
import FolderBrowserDialog from './FolderBrowserDialog'

export default function FoldersManager({ api, folders, onChange, onError }) {
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

  const handleToggle = async (folder) => {
    try {
      await api.updateMediaFolder(folder.id, { enabled: !folder.enabled })
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to update folder')
    }
  }

  const handleRemove = async (folder) => {
    if (!window.confirm(`Stop tracking ${folder.path}? Existing series/movies are kept.`)) return
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
        <button
          type="button"
          className="btn-choose-folder"
          onClick={() => setPicking(true)}
          style={{ marginLeft: 'auto' }}
        >
          + Add folder
        </button>
      </div>
      {folders.length === 0 ? (
        <p className="add-help" style={{ marginTop: 12 }}>
          No folders yet. Add one to start auto-discovering media.
        </p>
      ) : (
        <table style={{ width: '100%', marginTop: 12, borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ textAlign: 'left', fontSize: 12, color: 'var(--muted, #888)' }}>
              <th style={{ padding: '8px 4px' }}>Path</th>
              <th style={{ padding: '8px 4px' }}>Kind</th>
              <th style={{ padding: '8px 4px' }}>Last scanned</th>
              <th style={{ padding: '8px 4px' }}>Enabled</th>
              <th style={{ padding: '8px 4px' }}></th>
            </tr>
          </thead>
          <tbody>
            {folders.map((f) => (
              <tr key={f.id} style={{ borderTop: '1px solid rgba(255,255,255,0.08)' }}>
                <td style={{ padding: '10px 4px', fontFamily: 'monospace' }}>{f.path}</td>
                <td style={{ padding: '10px 4px' }}>{f.kind}</td>
                <td style={{ padding: '10px 4px', color: 'var(--muted, #888)', fontSize: 12 }}>
                  {f.lastScannedAt ? new Date(f.lastScannedAt).toLocaleString() : 'never'}
                </td>
                <td style={{ padding: '10px 4px' }}>
                  <input
                    type="checkbox"
                    checked={!!f.enabled}
                    onChange={() => handleToggle(f)}
                  />
                </td>
                <td style={{ padding: '10px 4px', textAlign: 'right' }}>
                  <button
                    type="button"
                    onClick={() => handleRemove(f)}
                    style={{ background: 'transparent', border: 0, color: '#c33', cursor: 'pointer' }}
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
