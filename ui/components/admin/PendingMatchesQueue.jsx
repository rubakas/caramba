import MatchCandidatePicker from './MatchCandidatePicker'

export default function PendingMatchesQueue({ api, imports, onChange, onError }) {
  if (imports.length === 0) {
    return (
      <section style={{ marginTop: 32 }}>
        <h2 style={{ margin: 0, fontSize: 20 }}>Pending matches</h2>
        <p className="add-help" style={{ marginTop: 12 }}>
          Nothing waiting to be matched. New media discovered in your folders will appear here.
        </p>
      </section>
    )
  }

  return (
    <section style={{ marginTop: 32 }}>
      <h2 style={{ margin: 0, fontSize: 20 }}>
        Pending matches <span style={{ color: 'var(--muted, #888)', fontWeight: 400, fontSize: 14 }}>({imports.length})</span>
      </h2>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16, marginTop: 12 }}>
        {imports.map((pi) => (
          <MatchCandidatePicker
            key={pi.id}
            api={api}
            pendingImport={pi}
            onChange={onChange}
            onError={onError}
          />
        ))}
      </div>
    </section>
  )
}
