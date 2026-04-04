import { HashRouter, Routes, Route } from 'react-router-dom'
import { lazy, Suspense } from 'react'
import { ToastProvider } from './context/ToastContext'
import { PlayerProvider } from './context/PlayerContext'
import ToastContainer from './components/ToastContainer'
import VideoPlayer from './components/VideoPlayer'
import Library from './pages/Library'
import SeriesShow from './pages/SeriesShow'
import SeriesNew from './pages/SeriesNew'
import Movies from './pages/Movies'
import MovieShow from './pages/MovieShow'
import MoviesNew from './pages/MoviesNew'
import History from './pages/History'
import Settings from './pages/Settings'
import Discover from './pages/Discover'
import UpdatePrompt from './components/UpdatePrompt'

// Dev-only: lazy-load playground so it's tree-shaken from production builds
const Playground = import.meta.env.DEV ? lazy(() => import('./pages/Playground')) : null

export default function App() {
  return (
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
  )
}
