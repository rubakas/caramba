import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'

export default function SeriesNew() {
  const navigate = useNavigate()
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  const handleChooseFolder = async () => {
    const path = await window.api.selectFolder()
    if (!path) return
    setLoading(true)
    setError(null)
    try {
      const result = await window.api.addSeries(path)
      if (result && result.slug) {
        navigate(`/series/${result.slug}`)
      } else {
        navigate('/')
      }
    } catch (err) {
      setError(err.message || 'Failed to add series')
      setLoading(false)
    }
  }

  return (
    <>
      <Navbar active="" />
      <main className="add-main">
        <div className="add-container">
          <h1 className="page-title">Add Series</h1>
          <p className="add-help">
            Choose a folder that contains MKV files with SxxExx naming.<br />
            The series name will be auto-detected from the folder name.
          </p>
          {error && <div className="alert">{error}</div>}
          <div className="add-form">
            <button
              type="button"
              className="btn-choose-folder"
              onClick={handleChooseFolder}
              disabled={loading}
            >
              {loading ? 'Scanning...' : 'Choose Folder...'}
            </button>
          </div>
        </div>
      </main>
    </>
  )
}
