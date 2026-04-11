import { useState, useEffect } from 'react'
import { refractive } from '@hashintel/refractive'
import { useGlassConfig } from '../config/useGlassConfig'

export default function UpdatePrompt() {
  const [phase, setPhase] = useState('idle') // idle | available | downloading | ready
  const [info, setInfo] = useState(null)
  const [progress, setProgress] = useState(0)
  const [error, setError] = useState(null)
  const [installing, setInstalling] = useState(false)
  const updatePromptGlass = useGlassConfig('update-prompt')

  useEffect(() => {
    // Pull: check if an update was already found before this component mounted
    window.api.checkForUpdate().then(info => {
      if (info && !info.error) {
        setInfo(info)
        setPhase('available')
      }
    })

    // Push: catch updates found after this component mounted
    const unsubAvailable = window.api.onUpdateAvailable((updateInfo) => {
      setInfo(updateInfo)
      setPhase('available')
    })
    const unsubProgress = window.api.onDownloadProgress(({ percent }) => {
      setProgress(percent)
    })
    return () => {
      unsubAvailable()
      unsubProgress()
    }
  }, [])

  const handleUpdate = async () => {
    setPhase('downloading')
    setProgress(0)
    setError(null)
    const result = await window.api.downloadUpdate()
    if (result.error) {
      setError(result.error)
      setPhase('available')
      return
    }
    setPhase('ready')
  }

  const handleInstall = async () => {
    setInstalling(true)
    setError(null)
    const result = await window.api.installUpdate()
    // Real macOS install quits the app — we only get here for simulation or errors
    if (result?.error) {
      setError(result.error)
      setInstalling(false)
      setPhase('ready') // stay on ready so user can retry or dismiss
      return
    }
    // Simulation mode: installUpdate returns { ok: true }
    if (result?.ok) setPhase('idle')
  }

  const handleDismiss = () => {
    setPhase('idle')
    setError(null)
  }

  if (phase === 'idle') return null

  return (
    <refractive.div className="update-prompt" refraction={updatePromptGlass}>
      <div className="update-prompt-body">
        {phase === 'available' && (
          <>
            <div className="update-prompt-title">Caramba {info?.version} is available</div>
            <div className="update-prompt-sub">A new version is ready to download.</div>
            {error && <div className="update-prompt-sub" style={{ color: 'var(--red)' }}>{error}</div>}
          </>
        )}
        {phase === 'downloading' && (
          <>
            <div className="update-prompt-title">Downloading update…</div>
            <div className="update-prompt-sub">{progress}%</div>
            <div className="update-progress-bar">
              <div className="update-progress-fill" style={{ width: `${progress}%` }} />
            </div>
          </>
        )}
        {phase === 'ready' && (
          <>
            <div className="update-prompt-title">Ready to install</div>
            <div className="update-prompt-sub">Caramba {info?.version} — the app will restart.</div>
            {error && <div className="update-prompt-sub" style={{ color: 'var(--red)' }}>{error}</div>}
          </>
        )}
      </div>

      <div className="update-prompt-actions">
        {phase === 'available' && (
          <>
            <button className="btn-ghost" onClick={handleDismiss}>Later</button>
            <button className="btn-primary" onClick={handleUpdate}>Update Now</button>
          </>
        )}
        {phase === 'ready' && (
          <>
            <button className="btn-ghost" onClick={handleDismiss} disabled={installing}>Later</button>
            <button className="btn-primary" onClick={handleInstall} disabled={installing}>
              {installing ? 'Restarting…' : 'Restart Now'}
            </button>
          </>
        )}
      </div>
    </refractive.div>
  )
}
