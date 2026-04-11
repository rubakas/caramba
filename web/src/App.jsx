import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { useMemo } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createHttpAdapter, httpCapabilities } from '@caramba/ui/adapters/http'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Library from '@caramba/ui/pages/Library'
import SeriesShow from '@caramba/ui/pages/SeriesShow'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Discover from '@caramba/ui/pages/Discover'
import History from '@caramba/ui/pages/History'

const API_BASE = import.meta.env.VITE_API_BASE || ''

export default function App() {
  const adapter = useMemo(() => createHttpAdapter(API_BASE), [])

  return (
    <ApiProvider adapter={adapter} capabilities={httpCapabilities}>
      <ToastProvider>
        <PlayerProvider>
          <BrowserRouter>
            <Routes>
              <Route path="/" element={<Library />} />
              <Route path="/series/:slug" element={<SeriesShow />} />
              <Route path="/movies" element={<Movies />} />
              <Route path="/movies/:slug" element={<MovieShow />} />
              <Route path="/discover" element={<Discover />} />
              <Route path="/history" element={<History />} />
            </Routes>
          </BrowserRouter>
          <VideoPlayer />
          <ToastContainer />
        </PlayerProvider>
      </ToastProvider>
    </ApiProvider>
  )
}
