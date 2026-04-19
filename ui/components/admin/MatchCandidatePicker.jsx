import { useState } from 'react'
import { useNavigate } from 'react-router-dom'

export default function MatchCandidatePicker({ api, pendingImport, onChange, onError }) {
  const navigate = useNavigate()
  const [busy, setBusy] = useState(null) // 'confirm' | 'ignore' | 'research' | null

  const candidates = pendingImport.candidates || []

  const handleConfirm = async (externalId) => {
    setBusy('confirm')
    try {
      const result = await api.confirmPendingImport(pendingImport.id, externalId)
      onChange()
      const slug = result?.series?.slug || result?.movie?.slug
      if (slug) {
        navigate(pendingImport.kind === 'movies' ? `/movies/${slug}` : `/series/${slug}`)
      }
    } catch (err) {
      onError(err.message || 'Failed to confirm match')
    } finally {
      setBusy(null)
    }
  }

  const handleIgnore = async () => {
    if (!window.confirm(`Ignore ${pendingImport.folderPath}? It won't be re-scanned automatically.`)) return
    setBusy('ignore')
    try {
      await api.ignorePendingImport(pendingImport.id)
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to ignore')
    } finally {
      setBusy(null)
    }
  }

  const handleResearch = async () => {
    setBusy('research')
    try {
      await api.researchPendingImport(pendingImport.id)
      onChange()
    } catch (err) {
      onError(err.message || 'Failed to re-search')
    } finally {
      setBusy(null)
    }
  }

  return (
    <article
      style={{
        background: 'rgba(255,255,255,0.04)',
        border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 10,
        padding: 16,
      }}
    >
      <header style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginBottom: 12 }}>
        <strong style={{ fontSize: 16 }}>
          {pendingImport.parsedName || '(no name)'}
          {pendingImport.parsedYear ? ` (${pendingImport.parsedYear})` : ''}
        </strong>
        <span style={{ fontSize: 12, color: 'var(--muted, #888)' }}>
          {pendingImport.kind} · {pendingImport.folderPath}
        </span>
        <div style={{ flex: 1 }} />
        <button type="button" onClick={handleResearch} disabled={!!busy}>
          {busy === 'research' ? 'Searching…' : 'Re-search'}
        </button>
        <button type="button" onClick={handleIgnore} disabled={!!busy} style={{ color: '#c33' }}>
          {busy === 'ignore' ? 'Ignoring…' : 'Ignore'}
        </button>
      </header>

      {pendingImport.error && (
        <div className="alert" style={{ marginBottom: 12 }}>
          {pendingImport.error}
        </div>
      )}

      {candidates.length === 0 ? (
        <p className="add-help">No candidates found. Try Re-search.</p>
      ) : (
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))',
            gap: 12,
          }}
        >
          {candidates.map((c) => (
            <div
              key={c.externalId}
              style={{
                background: 'rgba(0,0,0,0.3)',
                borderRadius: 8,
                overflow: 'hidden',
                display: 'flex',
                flexDirection: 'column',
              }}
            >
              {c.posterUrl ? (
                <img
                  src={c.posterUrl}
                  alt=""
                  style={{ width: '100%', aspectRatio: '2/3', objectFit: 'cover' }}
                />
              ) : (
                <div style={{ width: '100%', aspectRatio: '2/3', background: '#222', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#555' }}>
                  no poster
                </div>
              )}
              <div style={{ padding: 10, flex: 1, display: 'flex', flexDirection: 'column' }}>
                <strong style={{ fontSize: 14 }}>{c.name}</strong>
                <span style={{ fontSize: 12, color: 'var(--muted, #888)', marginTop: 2 }}>
                  {[c.year, c.rating ? `★ ${c.rating}` : null].filter(Boolean).join(' · ')}
                </span>
                {c.description && (
                  <p style={{ fontSize: 12, color: '#bbb', margin: '6px 0 8px', lineHeight: 1.3, maxHeight: 48, overflow: 'hidden' }}>
                    {c.description}
                  </p>
                )}
                <button
                  type="button"
                  className="btn-choose-folder"
                  style={{ marginTop: 'auto' }}
                  disabled={!!busy}
                  onClick={() => handleConfirm(c.externalId)}
                >
                  {busy === 'confirm' ? 'Confirming…' : 'This is the match'}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </article>
  )
}
