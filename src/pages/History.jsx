import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'
import { formatTime, progressPercent } from '../utils'

function groupByDate(histories) {
  const today = []
  const thisWeek = []
  const older = []

  const now = new Date()
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  const startOfWeek = new Date(startOfToday)
  startOfWeek.setDate(startOfWeek.getDate() - startOfWeek.getDay())

  for (const h of histories) {
    const d = new Date(h.started_at)
    if (d >= startOfToday) {
      today.push(h)
    } else if (d >= startOfWeek) {
      thisWeek.push(h)
    } else {
      older.push(h)
    }
  }

  return { today, thisWeek, older }
}

function formatDate(dateStr) {
  if (!dateStr) return ''
  const d = new Date(dateStr)
  return d.toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric'
  }) + ' at ' + d.toLocaleTimeString('en-US', {
    hour: '2-digit', minute: '2-digit', hour12: false
  })
}

function HistoryEntry({ h }) {
  const pct = progressPercent(h.progress_seconds, h.duration_seconds)
  const finished = h.progress_seconds && h.duration_seconds && (h.progress_seconds / h.duration_seconds) >= 0.9

  return (
    <div className="history-entry">
      <div className="history-entry-left">
        <span className="history-series">{h.series_name}</span>
        <span className="history-code">{h.code}</span>
      </div>
      <div className="history-entry-mid">
        <span className="history-ep-title">{h.episode_title}</span>
        <span className="history-meta">
          {formatDate(h.started_at)}
          {h.progress_seconds > 0 && h.duration_seconds > 0 && (
            <> &mdash; {pct}% ({formatTime(h.progress_seconds)} / {formatTime(h.duration_seconds)})</>
          )}
          {finished && <span className="badge badge--green">Completed</span>}
          {!finished && h.progress_seconds > 0 && <span className="badge badge--amber">Partial</span>}
        </span>
      </div>
    </div>
  )
}

export default function History() {
  const navigate = useNavigate()
  const [histories, setHistories] = useState([])
  const [stats, setStats] = useState({})
  const [loading, setLoading] = useState(true)

  const loadData = useCallback(async () => {
    try {
      const [h, s] = await Promise.all([
        window.api.listHistory(100),
        window.api.getHistoryStats(),
      ])
      setHistories(h)
      setStats(s)
    } catch (err) {
      console.error('Failed to load history:', err)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    loadData()
  }, [loadData])

  if (loading) return (
    <>
      <Navbar active="History" />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  const { today, thisWeek, older } = groupByDate(histories)
  const totalHours = stats.total_time ? (stats.total_time / 3600).toFixed(1) : '0'

  return (
    <>
      <Navbar active="History" />
      <main className="history-main">
        <h1 className="page-title">Watch History</h1>

        <div className="stats-row" style={{ marginBottom: 40 }}>
          <div className="stat"><span className="stat-val">{stats.total_series || 0}</span><span className="stat-lbl">Series</span></div>
          <div className="stat"><span className="stat-val">{stats.total_episodes || 0}</span><span className="stat-lbl">Episodes</span></div>
          <div className="stat"><span className="stat-val">{totalHours}</span><span className="stat-lbl">Hours</span></div>
          <div className="stat"><span className="stat-val">{histories.length}</span><span className="stat-lbl">Sessions</span></div>
        </div>

        {histories.length === 0 ? (
          <div className="empty-hero" style={{ padding: '40px 0' }}>
            <h2>No watch history yet</h2>
            <p>Start watching episodes and your history will appear here.</p>
            <a className="btn-primary" onClick={() => navigate('/')}>Browse Library</a>
          </div>
        ) : (
          <>
            {today.length > 0 && (
              <section className="history-section">
                <h2 className="history-section-title">Today</h2>
                {today.map(h => <HistoryEntry key={h.id} h={h} />)}
              </section>
            )}
            {thisWeek.length > 0 && (
              <section className="history-section">
                <h2 className="history-section-title">This Week</h2>
                {thisWeek.map(h => <HistoryEntry key={h.id} h={h} />)}
              </section>
            )}
            {older.length > 0 && (
              <section className="history-section">
                <h2 className="history-section-title">Earlier</h2>
                {older.map(h => <HistoryEntry key={h.id} h={h} />)}
              </section>
            )}
          </>
        )}
      </main>
    </>
  )
}
