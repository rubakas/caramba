import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'
import { useApi } from '../context/ApiContext'

export default function Learn() {
  const api = useApi()
  const navigate = useNavigate()
  const [episodes, setEpisodes] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [busyId, setBusyId] = useState(null)

  const refresh = useCallback(async () => {
    try {
      const list = await api.listLearningEpisodes()
      setEpisodes(list || [])
      setError(null)
    } catch (err) {
      setError(err.message || 'Failed to load episodes')
    } finally {
      setLoading(false)
    }
  }, [api])

  useEffect(() => {
    refresh()
    const id = setInterval(refresh, 5000)
    return () => clearInterval(id)
  }, [refresh])

  const handlePrepare = useCallback(async (ep) => {
    setBusyId(ep.id)
    try {
      await api.prepareSubtitle(ep.id)
      await refresh()
    } catch (err) {
      setError(err.message || 'Failed to prepare subtitle')
    } finally {
      setBusyId(null)
    }
  }, [api, refresh])

  return (
    <>
      <Navbar active="Learn" />
      <main className="add-main">
        <div className="add-container" style={{ maxWidth: 960 }}>
          <h1 className="page-title">Learning</h1>
          <p className="add-help">
            Pick a watched episode to extract its English subtitles. From there you can paste the SRT into Claude.ai (or another LLM) and turn it into a lesson with phrase translations and short video clips.
          </p>

          {error && <div className="alert" style={{ marginBottom: 16 }}>{error}</div>}

          {loading ? (
            <p className="add-help">Loading…</p>
          ) : episodes.length === 0 ? (
            <p className="add-help">
              No episodes are eligible yet. Make sure a few episodes have been probed (visit Admin → Scan now) and that they have text subtitle tracks (subrip / ass / webvtt). Image-based subs like PGS or DVD can't be converted to lessons.
            </p>
          ) : (
            <section
              style={{
                display: 'flex',
                flexDirection: 'column',
                gap: 8,
                marginTop: 16,
              }}
            >
              {episodes.map((ep) => (
                <EpisodeRow
                  key={ep.id}
                  episode={ep}
                  busy={busyId === ep.id}
                  onPrepare={() => handlePrepare(ep)}
                  onOpen={() => navigate(`/learn/new/${ep.id}`)}
                  onOpenLesson={(lessonId) => navigate(`/learn/lessons/${lessonId}`)}
                />
              ))}
            </section>
          )}
        </div>
      </main>
    </>
  )
}

function EpisodeRow({ episode, busy, onPrepare, onOpen, onOpenLesson }) {
  const subReady = !!episode.subtitle
  const lessons = episode.lessons || []
  return (
    <article
      style={{
        background: 'var(--surface, rgba(255,255,255,0.04))',
        border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 'var(--radius, 12px)',
        padding: '12px 16px',
        display: 'flex',
        flexDirection: 'column',
        gap: 12,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, color: 'var(--text-secondary, #a1a1a6)' }}>
            {episode.showName} · {episode.code}
            {episode.watched && (
              <span style={{ marginLeft: 8, color: 'var(--green, #30D158)' }}>· watched</span>
            )}
          </div>
          <div style={{ fontSize: 16, marginTop: 2 }}>{episode.title || episode.code}</div>
          {subReady && (
            <div style={{ fontSize: 12, color: 'var(--text-tertiary, #888)', marginTop: 4 }}>
              Subtitle ready · {(episode.subtitle.byteSize / 1024).toFixed(1)} KB · {episode.subtitle.language}
            </div>
          )}
        </div>
        {subReady ? (
          <button
            type="button"
            className="btn-choose-folder"
            onClick={onOpen}
            style={{ padding: '8px 16px' }}
          >
            {lessons.length > 0 ? 'New lesson' : 'Open lesson form'}
          </button>
        ) : (
          <button
            type="button"
            className="topnav-btn"
            onClick={onPrepare}
            disabled={busy}
          >
            {busy ? 'Preparing…' : 'Prepare lesson'}
          </button>
        )}
      </div>

      {lessons.length > 0 && (
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, paddingTop: 2 }}>
          {lessons.map((l) => (
            <button
              key={l.id}
              type="button"
              onClick={() => onOpenLesson(l.id)}
              style={{
                background: 'rgba(10, 132, 255, 0.12)',
                color: 'var(--accent, #0A84FF)',
                border: '1px solid rgba(10, 132, 255, 0.25)',
                borderRadius: 16,
                padding: '4px 12px',
                fontSize: 12,
                cursor: 'pointer',
                font: 'inherit',
              }}
              title={new Date(l.createdAt).toLocaleString()}
            >
              Lesson #{l.id} · {l.phraseCount} phrase{l.phraseCount === 1 ? '' : 's'}
              {l.status !== 'ready' && ` · ${l.status}`}
            </button>
          ))}
        </div>
      )}
    </article>
  )
}
