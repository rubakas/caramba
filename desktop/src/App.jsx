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
  // libmpv when capability detection says the native module is available,
  // hls.js otherwise. This is a runtime fact, not a user preference —
  // libmpv is strictly a superset (broader codec coverage, fewer
  // transcodes) and the DeviceProfile already declares per-engine
  // capabilities to the server. Surfaced as `useEmbedMpv` for the
  // adapter; null while detection is in flight.
  const [useEmbedMpv, setUseEmbedMpv] = useState(null)
  const [mpvCapabilities, setMpvCapabilities] = useState(null)

  // Initial bootstrap: load saved server URL + probe health.
  useEffect(() => {
    let cancelled = false
    ;(async () => {
      try {
        const cfg = await window.api.getServerConfig()
        if (cancelled) return
        const url = cfg?.serverUrl || ''

        // libmpv embed is intentionally disabled — see plan file Part 2
        // notes. mpv 0.41 + Electron on macOS can't be embedded
        // cleanly (mpv creates its own NSWindow that we can't make
        // visually indistinguishable from Electron's, and the
        // mpv_render_context path needs more native work than is
        // justified for an Electron shell). Desktop uses hls.js
        // through the same VideoPlayer the web client uses. Re-enable
        // by setting VITE_CARAMBA_FORCE_LIBMPV=1 if you want to try
        // the embed path again.
        const forceLibmpv = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_CARAMBA_FORCE_LIBMPV === '1') ||
                            (typeof window !== 'undefined' && window.__caramba_force_libmpv__ === true)
        let mpvAvailable = false
        if (forceLibmpv && window.api?.getMpvCapabilities) {
          try {
            const caps = await window.api.getMpvCapabilities()
            if (!cancelled && caps && !caps.error && Array.isArray(caps.decoders) && caps.decoders.length > 0) {
              setMpvCapabilities(caps)
              mpvAvailable = true
            }
          } catch (err) {
            console.warn('[App] mpv capability probe failed; using hls.js engine:', err?.message)
          }
        }
        if (!cancelled) setUseEmbedMpv(mpvAvailable)

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

  const adapterAndCaps = useMemo(() => {
    if (phase !== 'ready' || !serverUrl || useEmbedMpv === null) return null
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
