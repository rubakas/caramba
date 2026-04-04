import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { refractive } from '@hashintel/refractive'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import PosterCard from '../components/PosterCard'
import { useGlassConfig } from '../config/useGlassConfig'

const FilmIcon = () => (
  <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18"/>
    <line x1="7" y1="2" x2="7" y2="22"/><line x1="17" y1="2" x2="17" y2="22"/>
    <line x1="2" y1="12" x2="22" y2="12"/>
    <line x1="2" y1="7" x2="7" y2="7"/><line x1="2" y1="17" x2="7" y2="17"/>
    <line x1="17" y1="17" x2="22" y2="17"/><line x1="17" y1="7" x2="22" y2="7"/>
  </svg>
)

export default function Library() {
  const navigate = useNavigate()
  const [seriesList, setSeriesList] = useState([])
  const [resumables, setResumables] = useState({})
  const [loading, setLoading] = useState(true)
  const navActionGlass = useGlassConfig('nav-action')
  const primaryBtnGlass = useGlassConfig('primary-btn')

  const loadData = useCallback(async () => {
    try {
      const all = await window.api.listSeries()
      setSeriesList(all)
      // Check resumable for each series
      const res = {}
      for (const s of all) {
        const ep = await window.api.getResumable(s.slug)
        if (ep) res[s.slug] = true
      }
      setResumables(res)
    } catch (err) {
      console.error('Failed to load series:', err)
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    loadData()
    const handleStop = () => loadData()
    window.addEventListener('playback-stopped', handleStop)
    const unsubVlc = window.api.onVlcPlaybackEnded(() => loadData())
    return () => {
      window.removeEventListener('playback-stopped', handleStop)
      unsubVlc()
    }
  }, [loadData])

  if (loading) return (
    <>
      <Navbar active="Library" rightContent={
        <refractive.a className="topnav-action" onClick={() => navigate('/series/new')} refraction={navActionGlass}>+ Add Series</refractive.a>
      } />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  return (
    <>
      <Navbar active="Library" rightContent={
        <refractive.a className="topnav-action" onClick={() => navigate('/series/new')} refraction={navActionGlass}>+ Add Series</refractive.a>
      } />
      <NowPlaying />
      {seriesList.length === 0 ? (
        <main className="empty-hero">
          <div className="empty-icon"><FilmIcon /></div>
          <h2>Your Library is Empty</h2>
          <p>Add a series by pointing to a media folder on your Mac.</p>
          <refractive.a className="btn-primary" onClick={() => navigate('/series/new')} refraction={primaryBtnGlass}>Add Your First Series</refractive.a>
        </main>
      ) : (
        <main className="library">
          <h2 className="section-title">My Library</h2>
          <div className="series-grid">
            {seriesList.map(s => (
              <PosterCard
                key={s.slug}
                item={s}
                type="series"
                resumable={!!resumables[s.slug]}
              />
            ))}
            <div className="series-card card-add" onClick={() => navigate('/series/new')}>
              <div className="card-poster">
                <div className="card-poster-fallback card-add-icon">+</div>
              </div>
              <div className="card-body">
                <h3 className="card-title">Add Series</h3>
                <p className="card-meta">From a local folder</p>
              </div>
            </div>
          </div>
        </main>
      )}
    </>
  )
}
