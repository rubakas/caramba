import { HashRouter, Routes, Route } from 'react-router-dom'
import { lazy, Suspense, useMemo } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createLocalAdapter, localCapabilities } from '@caramba/ui/adapters/local'
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
import History from '@caramba/ui/pages/History'
import Settings from '@caramba/ui/pages/Settings'
import Discover from '@caramba/ui/pages/Discover'
import UpdatePrompt from '@caramba/ui/components/UpdatePrompt'

// Dev-only: lazy-load playground so it's tree-shaken from production builds
const Playground = import.meta.env.DEV ? lazy(() => import('@caramba/ui/pages/Playground')) : null

export default function App() {
  const adapter = useMemo(() => createLocalAdapter(), [])

  return (
    <ApiProvider adapter={adapter} capabilities={localCapabilities}>
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
              <Route path="/discover" element={<Discover />} />
              <Route path="/history" element={<History />} />
              <Route path="/settings" element={<Settings />} />
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
