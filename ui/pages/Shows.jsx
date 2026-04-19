import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { refractive } from '../config/refractive'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import PosterCard from '../components/PosterCard'
import { useGlassConfig } from '../config/useGlassConfig'
import { useApi, useCapabilities } from '../context/ApiContext'

const isAndroidTV = typeof window !== 'undefined' && window.Capacitor?.isNativePlatform?.() === true

const FilmIcon = () => (
  <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18"/>
    <line x1="7" y1="2" x2="7" y2="22"/><line x1="17" y1="2" x2="17" y2="22"/>
    <line x1="2" y1="12" x2="22" y2="12"/>
    <line x1="2" y1="7" x2="7" y2="7"/><line x1="2" y1="17" x2="7" y2="17"/>
    <line x1="17" y1="17" x2="22" y2="17"/><line x1="17" y1="7" x2="22" y2="7"/>
  </svg>
)

export default function Shows() {
  const navigate = useNavigate()
  const api = useApi()
  const { canAdd, hasNowPlaying } = useCapabilities()
  const [showsList, setShowsList] = useState([])
  const [loading, setLoading] = useState(true)
  const navActionGlass = useGlassConfig('nav-action')
  const primaryBtnGlass = useGlassConfig('primary-btn')

  const loadData = useCallback(async () => {
    try {
      const all = await api.listShows()
      setShowsList(all)
    } catch (err) {
      console.error('Failed to load shows:', err)
    } finally {
      setLoading(false)
    }
  }, [api])

  useEffect(() => {
    loadData()
    const handleStop = () => loadData()
    window.addEventListener('playback-stopped', handleStop)
    const unsubVlc = api.onVlcPlaybackEnded(() => loadData())
    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
    }
  }, [loadData, api])

  const addButton = canAdd ? (
    <refractive.a className="topnav-action" onClick={() => navigate('/shows/new')} refraction={navActionGlass}>+ Add Show</refractive.a>
  ) : null

  if (loading) return (
    <>
      <Navbar active="Shows" rightContent={addButton} />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  return (
    <>
      <Navbar active="Shows" rightContent={addButton} />
      {hasNowPlaying && <NowPlaying />}
      {showsList.length === 0 ? (
        <main className="empty-hero">
          <div className="empty-icon"><FilmIcon /></div>
          <h2>No shows yet</h2>
          {canAdd ? (
            <>
              <p>Add a show by pointing to a media folder on your Mac.</p>
              <refractive.a className="btn-primary" onClick={() => navigate('/shows/new')} refraction={primaryBtnGlass}>Add Your First Show</refractive.a>
            </>
          ) : (
            <p>No shows have been added yet.</p>
          )}
        </main>
      ) : (
        <main className="library">
          <h2 className="section-title">My Shows</h2>
          <div className="series-grid">
            {showsList.map((s, idx) => (
              <PosterCard
                key={s.slug}
                item={s}
                type="show"
                resumable={!!s.has_continue}
                autoFocus={isAndroidTV && idx === 0}
              />
            ))}
            {canAdd && (
              <div className="series-card card-add" onClick={() => navigate('/shows/new')}>
                <div className="card-poster">
                  <div className="card-poster-fallback card-add-icon">+</div>
                </div>
                <div className="card-body">
                  <h3 className="card-title">Add Show</h3>
                  <p className="card-meta">From a local folder</p>
                </div>
              </div>
            )}
          </div>
        </main>
      )}
    </>
  )
}
