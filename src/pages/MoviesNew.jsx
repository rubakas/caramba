import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'

export default function MoviesNew() {
  const navigate = useNavigate()
  const [filePaths, setFilePaths] = useState([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  const handleChooseFiles = async () => {
    const paths = await window.api.selectFiles()
    if (paths && paths.length > 0) setFilePaths(paths)
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (filePaths.length === 0) return
    setLoading(true)
    setError(null)
    try {
      const results = await window.api.addMovies(filePaths)
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

  const fileNames = filePaths.map(p => p.split('/').pop())

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
          <form className="add-form" onSubmit={handleSubmit}>
            <div className="field">
              <div className="folder-picker">
                <button type="button" className="btn-choose-folder" onClick={handleChooseFiles}>
                  {filePaths.length > 0 ? 'Change Files...' : 'Choose Files...'}
                </button>
                <span
                  className={`folder-path${filePaths.length > 0 ? ' has-path' : ''}`}
                  title={fileNames.join('\n')}
                >
                  {filePaths.length > 0
                    ? `${filePaths.length} file${filePaths.length > 1 ? 's' : ''} selected`
                    : 'No files selected'
                  }
                </span>
              </div>
            </div>
            {filePaths.length > 0 && (
              <div className="add-actions">
                <button type="submit" className="btn-primary" disabled={loading}>
                  {loading ? 'Adding...' : 'Add Movies'}
                </button>
                <button type="button" className="btn-ghost" onClick={() => navigate('/movies')}>
                  Cancel
                </button>
              </div>
            )}
          </form>
        </div>
      </main>
    </>
  )
}
