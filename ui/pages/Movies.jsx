import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { refractive } from '../config/refractive'
import Navbar from '../components/Navbar'
import NowPlaying from '../components/NowPlaying'
import PosterCard from '../components/PosterCard'
import { useGlassConfig } from '../config/useGlassConfig'
import { useApi, useCapabilities } from '../context/ApiContext'

const CameraIcon = () => (
  <svg width="64" height="64" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
    <polygon points="23 7 16 12 23 17 23 7"/>
    <rect x="1" y="5" width="15" height="14" rx="2" ry="2"/>
  </svg>
)

export default function Movies() {
  const navigate = useNavigate()
  const api = useApi()
  const { canAdd, hasNowPlaying } = useCapabilities()
  const [movies, setMovies] = useState([])
  const [loading, setLoading] = useState(true)
  const navActionGlass = useGlassConfig('nav-action')
  const primaryBtnGlass = useGlassConfig('primary-btn')

  const loadData = useCallback(async () => {
    try {
      const all = await api.listMovies()
      setMovies(all)
    } catch (err) {
      console.error('Failed to load movies:', err)
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
    <refractive.a className="topnav-action" onClick={() => navigate('/movies/new')} refraction={navActionGlass}>+ Add Movie</refractive.a>
  ) : null

  if (loading) return (
    <>
      <Navbar active="Movies" rightContent={addButton} />
      <div style={{ padding: '120px 48px', textAlign: 'center', color: 'var(--text-tertiary)' }}>Loading...</div>
    </>
  )

  return (
    <>
      <Navbar active="Movies" rightContent={addButton} />
      {hasNowPlaying && <NowPlaying />}
      {movies.length === 0 ? (
        <main className="empty-hero">
          <div className="empty-icon"><CameraIcon /></div>
          <h2>No Movies Yet</h2>
          {canAdd ? (
            <>
              <p>Add a movie by selecting an MKV file from your Mac.</p>
              <refractive.a className="btn-primary" onClick={() => navigate('/movies/new')} refraction={primaryBtnGlass}>Add Your First Movie</refractive.a>
            </>
          ) : (
            <p>No movies have been added yet.</p>
          )}
        </main>
      ) : (
        <main className="library">
          <h2 className="section-title">Movies</h2>
          <div className="series-grid">
            {movies.map(m => (
              <PosterCard key={m.slug} item={m} type="movie" />
            ))}
            {canAdd && (
              <div className="series-card card-add" onClick={() => navigate('/movies/new')}>
                <div className="card-poster">
                  <div className="card-poster-fallback card-add-icon">+</div>
                </div>
                <div className="card-body">
                  <h3 className="card-title">Add Movie</h3>
                  <p className="card-meta">From a local file</p>
                </div>
              </div>
            )}
          </div>
        </main>
      )}
    </>
  )
}
