import { HashRouter, Routes, Route } from 'react-router-dom'
import Library from './pages/Library'
import SeriesShow from './pages/SeriesShow'
import SeriesNew from './pages/SeriesNew'
import Movies from './pages/Movies'
import MovieShow from './pages/MovieShow'
import MoviesNew from './pages/MoviesNew'
import History from './pages/History'
import Settings from './pages/Settings'

export default function App() {
  return (
    <HashRouter>
      <Routes>
        <Route path="/" element={<Library />} />
        <Route path="/series/new" element={<SeriesNew />} />
        <Route path="/series/:slug" element={<SeriesShow />} />
        <Route path="/movies" element={<Movies />} />
        <Route path="/movies/new" element={<MoviesNew />} />
        <Route path="/movies/:slug" element={<MovieShow />} />
        <Route path="/history" element={<History />} />
        <Route path="/settings" element={<Settings />} />
      </Routes>
    </HashRouter>
  )
}
