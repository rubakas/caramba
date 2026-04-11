import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'

export default function MoviesNew() {
  const navigate = useNavigate()
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  const handleChooseFiles = async () => {
    const paths = await window.api.selectFiles()
    if (!paths || paths.length === 0) return
    setLoading(true)
    setError(null)
    try {
      const results = await window.api.addMovies(paths)
      if (results && results.length === 1) {
        navigate(`/movies/${results[0].slug}`)
      } else {
        navigate('/movies')
      }
    } catch (err) {
      setError(err.message || 'Failed to add movies')
      setLoading(false)
    }
  }

  return (
    <>
      <Navbar active="Movies" />
      <main className="add-main">
        <div className="add-container">
          <h1 className="page-title">Add Movies</h1>
          <p className="add-help">
            Select one or more MKV files from your Mac.<br />
            Metadata will be fetched automatically.
          </p>
          {error && <div className="alert">{error}</div>}
          <div className="add-form">
            <button
              type="button"
              className="btn-choose-folder"
              onClick={handleChooseFiles}
              disabled={loading}
            >
              {loading ? 'Adding...' : 'Choose Files...'}
            </button>
          </div>
        </div>
      </main>
    </>
  )
}
