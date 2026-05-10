import { HashRouter, Routes, Route } from 'react-router-dom'
import { lazy, Suspense, useState, useEffect, useMemo, useCallback } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createDesktopAdapter, getDesktopCapabilities } from '@caramba/ui/adapters/desktop'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import ServerSetup from '@caramba/ui/components/ServerSetup'
import Shows from '@caramba/ui/pages/Shows'
import Show from '@caramba/ui/pages/Show'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Settings from '@caramba/ui/pages/Settings'
import Admin from '@caramba/ui/pages/Admin'
import UpdatePrompt from '@caramba/ui/components/UpdatePrompt'

const Playground = import.meta.env.DEV ? lazy(() => import('@caramba/ui/pages/Playground')) : null

// Phases of bootstrap:
//   - 'loading': reading saved server URL + probing /api/health
//   - 'setup':   no saved URL, or saved URL is unreachable; show ServerSetup
//   - 'ready':   adapter wired, render the app
async function probeHealth(url) {
  if (!url) return false
  try {
    const res = await fetch(`${url.replace(/\/+$/, '')}/api/health`, {
      signal: AbortSignal.timeout(5000),
    })
    if (!res.ok) return false
    const json = await res.json().catch(() => ({}))
    return json?.status === 'ok'
  } catch {
    return false
  }
}

export default function App() {
  const [phase, setPhase] = useState('loading')
  const [serverUrl, setServerUrl] = useState(null)
  const [setupReason, setSetupReason] = useState(null)
  const [useEmbedMpv, setUseEmbedMpv] = useState(true)
  const [mpvCapabilities, setMpvCapabilities] = useState(null)

  // Initial bootstrap: load saved server URL + probe health.
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const cfg = await window.api.getServerConfig()
        const prefs = await window.api.getPreferences().catch(() => null)
        if (cancelled) return
        const url = cfg?.serverUrl || ''
        // libmpv is the default desktop engine — broader codec coverage,
        // no MSE codec quirks. Only fall back to hls.js when the user
        // explicitly picks it in Settings.
        const engine = prefs?.playerEngine || 'libmpv'
        setUseEmbedMpv(engine === 'libmpv')

        // Fetch the engine's decoder + demuxer lists so the device
        // profile reflects this specific libmpv build, not the
        // hardcoded fallback. Best-effort — the profile builder falls
        // back gracefully if this fails (e.g. native module not built).
        if (engine === 'libmpv') {
          try {
            const caps = await window.api.getMpvCapabilities()
            if (!cancelled && caps && !caps.error) setMpvCapabilities(caps)
          } catch {}
        }
        if (!url) {
          setSetupReason('First launch — let’s find your Caramba server.')
          setPhase('setup')
          return
        }
        const healthy = await probeHealth(url)
        if (cancelled) return
        if (!healthy) {
          setServerUrl(url)
          setSetupReason('That server is unreachable. Pick another or fix the URL.')
          setPhase('setup')
          return
        }
        setServerUrl(url)
        setPhase('ready')
      } catch (err) {
        if (cancelled) return
        console.warn('[App] bootstrap failed:', err)
        setSetupReason('Couldn’t read saved settings. Pick a server to continue.')
        setPhase('setup')
      }
    })()
    return () => { cancelled = true }
  }, [])

  const handleConnected = useCallback(async (url) => {
    try {
      await window.api.setServerConfig({ serverUrl: url })
    } catch (err) {
      console.warn('[App] failed to persist server URL:', err)
    }
    setServerUrl(url)
    setSetupReason(null)
    setPhase('ready')
  }, [])

  const handleChangeServer = useCallback(() => {
    setSetupReason('Pick a different server.')
    setPhase('setup')
  }, [])

  const handlePlayerEngineChange = useCallback(async (engine) => {
    try {
      await window.api.setPreferences({ playerEngine: engine })
    } catch {}
    setUseEmbedMpv(engine === 'libmpv')
  }, [])

  const adapterAndCaps = useMemo(() => {
    if (phase !== 'ready' || !serverUrl) return null
    return {
      adapter: createDesktopAdapter(serverUrl, { useEmbedMpv, mpvCapabilities }),
      capabilities: getDesktopCapabilities({ useEmbedMpv }),
    }
  }, [phase, serverUrl, useEmbedMpv, mpvCapabilities])

  if (phase === 'loading') {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', background: '#000' }} />
    )
  }

  if (phase === 'setup' || !adapterAndCaps) {
    return (
      <ServerSetup
        initialUrl={serverUrl || ''}
        onConnected={handleConnected}
        reason={setupReason}
      />
    )
  }

  return (
    <ApiProvider adapter={adapterAndCaps.adapter} capabilities={adapterAndCaps.capabilities}>
      <ToastProvider>
        <PlayerProvider>
          <HashRouter>
            <Routes>
              <Route path="/" element={<Shows />} />
              <Route path="/shows/:slug" element={<Show />} />
              <Route path="/movies" element={<Movies />} />
              <Route path="/movies/:slug" element={<MovieShow />} />
              <Route path="/settings" element={
                <Settings
                  serverUrl={serverUrl}
                  onChangeServer={handleChangeServer}
                  playerEngine={useEmbedMpv ? 'libmpv' : 'hlsjs'}
                  onPlayerEngineChange={handlePlayerEngineChange}
                />
              } />
              <Route path="/admin" element={<Admin />} />
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
