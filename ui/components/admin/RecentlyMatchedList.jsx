import { useState } from 'react'

export default function RecentlyMatchedList({ api, imports, onChange, onError }) {
  if (!imports || imports.length === 0) return null

  return (
    <section style={{ marginTop: 32 }}>
      <h2 style={{ margin: 0, fontSize: 20 }}>
        Recently matched <span style={{ color: 'var(--muted, #888)', fontWeight: 400, fontSize: 14 }}>({imports.length})</span>
      </h2>
      <p className="add-help" style={{ marginTop: 8 }}>
        Picked the wrong one? Re-match destroys the imported entry and re-opens it for picking.
      </p>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 12 }}>
        {imports.map((pi) => (
          <RecentlyMatchedRow key={pi.id} api={api} pendingImport={pi} onChange={onChange} onError={onError} />
        ))}
      </div>
    </section>
  )
}

function RecentlyMatchedRow({ api, pendingImport, onChange, onError }) {
  const [busy, setBusy] = useState(false)

  const matched = (pendingImport.candidates || []).find(
    (c) => String(c.externalId) === String(pendingImport.chosenExternalId)
  )
  const matchedName = matched?.name

  const handleRematch = async () => {
    const what = matchedName || pendingImport.parsedName || pendingImport.folderPath
    if (!window.confirm(`Re-match "${what}"? This will delete the imported entry and re-open it for picking.`)) return
    setBusy(true)
    try {
      await api.rematchPendingImport(pendingImport.id)
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to re-match')
    } finally {
      setBusy(false)
    }
  }

  return (
    <article
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 12,
        background: 'rgba(255,255,255,0.04)',
        border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 10,
        padding: '10px 14px',
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 500, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {matchedName || pendingImport.parsedName || '(no name)'}
          {matchedName && pendingImport.parsedName && matchedName !== pendingImport.parsedName && (
            <span style={{ color: 'var(--text-tertiary, #888)', fontWeight: 400, marginLeft: 8, fontSize: 12 }}>
              ← {pendingImport.parsedName}
            </span>
          )}
        </div>
        <div style={{ fontSize: 12, color: 'var(--text-tertiary, #888)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {pendingImport.kind} · {pendingImport.folderPath}
        </div>
      </div>
      <button type="button" className="topnav-btn" onClick={handleRematch} disabled={busy}>
        {busy ? 'Re-matching…' : 'Re-match'}
      </button>
    </article>
  )
}
