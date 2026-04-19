import { HashRouter, Routes, Route } from 'react-router-dom'
import { lazy, Suspense, useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createLocalAdapter, localCapabilities } from '@caramba/ui/adapters/local'
import { createHybridAdapter } from '@caramba/ui/adapters/hybrid'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Library from '@caramba/ui/pages/Library'
import SeriesShow from '@caramba/ui/pages/SeriesShow'
import SeriesNew from '@caramba/ui/pages/SeriesNew'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import MoviesNew from '@caramba/ui/pages/MoviesNew'
import Settings from '@caramba/ui/pages/Settings'
import UpdatePrompt from '@caramba/ui/components/UpdatePrompt'

// Dev-only: lazy-load playground so it's tree-shaken from production builds
const Playground = import.meta.env.DEV ? lazy(() => import('@caramba/ui/pages/Playground')) : null

export default function App() {
  const [apiMode, setApiMode] = useState(null)   // null = loading, { enabled, server_url }
  const [apiConnected, setApiConnected] = useState(false)
  const hybridRef = useRef(null)

  // Load API mode config on mount
  useEffect(() => {
    window.api.getApiMode().then(config => {
      setApiMode(config || { enabled: false, server_url: null })
    }).catch(() => {
      setApiMode({ enabled: false, server_url: null })
    })
  }, [])

  // Called from Settings when API mode changes
  const handleApiModeChange = useCallback((newConfig) => {
    setApiMode(newConfig)
  }, [])

  // Create adapter based on API mode config
  const { adapter, capabilities } = useMemo(() => {
    // Clean up previous hybrid adapter
    if (hybridRef.current) {
      hybridRef.current.destroy()
      hybridRef.current = null
    }

    if (!apiMode || !apiMode.enabled || !apiMode.server_url) {
      return { adapter: createLocalAdapter(), capabilities: localCapabilities }
    }

    const hybrid = createHybridAdapter({
      serverUrl: apiMode.server_url,
      localPlayback: apiMode.local_playback !== false,
      onConnectionChange: (connected) => setApiConnected(connected),
    })
    hybridRef.current = hybrid
    return { adapter: hybrid.adapter, capabilities: hybrid.capabilities }
  }, [apiMode])

  // Clean up on unmount
  useEffect(() => {
    return () => {
      if (hybridRef.current) {
        hybridRef.current.destroy()
        hybridRef.current = null
      }
    }
  }, [])

  // Don't render until we know the API mode config
  if (!apiMode) return null

  return (
    <ApiProvider adapter={adapter} capabilities={capabilities}>
      <ToastProvider>
        <PlayerProvider>
          <HashRouter>
            <Routes>
              <Route path="/" element={<Library />} />
              <Route path="/series/new" element={<SeriesNew />} />
              <Route path="/series/:slug" element={<SeriesShow />} />
              <Route path="/movies" element={<Movies />} />
              <Route path="/movies/new" element={<MoviesNew />} />
              <Route path="/movies/:slug" element={<MovieShow />} />
              <Route path="/settings" element={
                <Settings
                  apiMode={apiMode}
                  apiConnected={apiConnected}
                  onApiModeChange={handleApiModeChange}
                />
              } />
              {import.meta.env.DEV && Playground && (
                <Route path="/playground" element={<Suspense fallback={null}><Playground /></Suspense>} />
              )}
            </Routes>
            <VideoPlayer />
          </HashRouter>
          <ToastContainer />
          <UpdatePrompt />
        </PlayerProvider>
      </ToastProvider>
    </ApiProvider>
  )
}
