import { useState, useEffect, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import Navbar from '../components/Navbar'
import { useApi } from '../context/ApiContext'

export default function Lesson() {
  const { id } = useParams()
  const api = useApi()
  const [lesson, setLesson] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const refresh = useCallback(async () => {
    try {
      const data = await api.getLesson(id)
      setLesson(data)
      setError(null)
    } catch (err) {
      setError(err.message || 'Failed to load lesson')
    } finally {
      setLoading(false)
    }
  }, [api, id])

  useEffect(() => {
    refresh()
  }, [refresh])

  // Phase 3 will poll until every phrase has clipStatus === 'ready'. For
  // Phase 2 we don't render clips, so a single fetch is enough.
  useEffect(() => {
    if (!lesson || lesson.status === 'ready' || lesson.status === 'failed') return
    const interval = setInterval(refresh, 2000)
    return () => clearInterval(interval)
  }, [lesson, refresh])

  return (
    <>
      <Navbar active="Learn" />
      <main className="add-main">
        <div className="add-container" style={{ maxWidth: 760 }}>
          <h1 className="page-title">Lesson</h1>
          {error && <div className="alert" style={{ marginBottom: 16 }}>{error}</div>}

          {loading ? (
            <p className="add-help">Loading…</p>
          ) : lesson ? (
            <>
              <p className="add-help" style={{ marginBottom: 24 }}>
                {lesson.phrases.length} phrase{lesson.phrases.length === 1 ? '' : 's'} · status: <strong>{lesson.status}</strong>
                {lesson.provider && lesson.provider !== 'manual' && <> · model: {lesson.model || lesson.provider}</>}
              </p>

              <section style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
                {lesson.phrases.map((p) => (
                  <PhraseCard key={p.id} phrase={p} />
                ))}
              </section>
            </>
          ) : null}
        </div>
      </main>
    </>
  )
}

function PhraseCard({ phrase }) {
  return (
    <article
      style={{
        background: 'var(--surface, rgba(255,255,255,0.04))',
        border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 'var(--radius, 12px)',
        padding: 20,
      }}
    >
      {/* Phase 3 will render <video src={phrase.clipUrl}> here when clipStatus === 'ready'. */}
      {phrase.clipUrl ? (
        <video
          src={phrase.clipUrl}
          controls
          muted
          preload="metadata"
          style={{ width: '100%', borderRadius: 8, marginBottom: 12, background: '#000' }}
        />
      ) : (
        <div
          style={{
            fontSize: 11,
            color: 'var(--text-tertiary, #888)',
            marginBottom: 12,
            letterSpacing: 0.5,
            textTransform: 'uppercase',
          }}
        >
          {phrase.clipStatus === 'failed'
            ? `Clip failed${phrase.clipError ? `: ${phrase.clipError}` : ''}`
            : `Clip ${phrase.clipStatus} · ${formatTimestamp(phrase.startMs)} – ${formatTimestamp(phrase.endMs)}`}
        </div>
      )}

      <div style={{ fontSize: 20, fontWeight: 500, lineHeight: 1.35 }}>{phrase.phrase}</div>
      {phrase.translation && (
        <div style={{ fontSize: 18, color: 'var(--accent, #0A84FF)', marginTop: 6, lineHeight: 1.35 }}>
          {phrase.translation}
        </div>
      )}
      {phrase.meaning && (
        <div style={{ fontSize: 14, color: 'var(--text-secondary, #a1a1a6)', marginTop: 10, lineHeight: 1.5 }}>
          {phrase.meaning}
        </div>
      )}
    </article>
  )
}

function formatTimestamp(ms) {
  if (typeof ms !== 'number') return '?'
  const total = Math.floor(ms / 1000)
  const m = Math.floor(total / 60).toString().padStart(2, '0')
  const s = (total % 60).toString().padStart(2, '0')
  return `${m}:${s}`
}
