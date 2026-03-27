import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Navbar from '../components/Navbar'

export default function SeriesNew() {
  const navigate = useNavigate()
  const [folderPath, setFolderPath] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState(null)

  const handleChooseFolder = async () => {
    const path = await window.api.selectFolder()
    if (path) setFolderPath(path)
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!folderPath.trim()) return
    setLoading(true)
    setError(null)
    try {
      const result = await window.api.addSeries(folderPath.trim())
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
          <form className="add-form" onSubmit={handleSubmit}>
            <div className="field">
              <div className="folder-picker">
                <button type="button" className="btn-choose-folder" onClick={handleChooseFolder}>
                  {folderPath ? 'Change Folder...' : 'Choose Folder...'}
                </button>
                <span className={`folder-path${folderPath ? ' has-path' : ''}`}>
                  {folderPath || 'No folder selected'}
                </span>
              </div>
            </div>
            {folderPath && (
              <div className="add-actions">
                <button type="submit" className="btn-primary" disabled={loading}>
                  {loading ? 'Scanning...' : 'Scan & Add'}
                </button>
                <button type="button" className="btn-ghost" onClick={() => navigate('/')}>
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
