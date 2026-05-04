import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { useMemo, useState, useEffect } from 'react'
import * as Sentry from '@sentry/capacitor'
import * as SentryReact from '@sentry/react'
import { sentryInit } from '@caramba/ui/sentry/init'
import { ApiProvider } from '@caramba/ui/context/ApiContext'

sentryInit({
  Sentry: { ...SentryReact, ...Sentry, init: Sentry.init },
  dsn: import.meta.env.VITE_SENTRY_DSN,
  platform: 'android-tv',
  release: __SENTRY_RELEASE__,
  isDev: import.meta.env.DEV,
})
import { createHttpAdapter, httpCapabilities } from '@caramba/ui/adapters/http'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Shows from '@caramba/ui/pages/Shows'
import Show from '@caramba/ui/pages/Show'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Settings from '@caramba/ui/pages/Settings'
import { Capacitor } from '@capacitor/core'

const isAndroidTV = Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

// Android TV capabilities - show Settings with API URL config, no file management
const androidTvCapabilitiesBase = {
  ...httpCapabilities,
  hasSettings: true,
  canDownload: false,
  canAdd: false,
  canManage: false,
  canOpenExternal: false,
}

// Web capabilities
const webCapabilities = {
  ...httpCapabilities,
  hasSettings: true,
}

// One-shot probe for the native player plugin. The Capacitor plugin's
// isAvailable() returns true on a real device with the APK installed; the
// web fallback (CarambaPlayerWeb) returns false. Anything else (plugin
// missing, older APK without the plugin registered) is treated as false so
// the React layer cleanly falls back to the WebView <video> + hls.js path.
async function probeNativePlayer() {
  // Loud breadcrumb: prints to DevTools console + Capacitor/Console tag in
  // adb logcat. Lets us see at a glance whether the plugin is wired up.
  const has = !!window.Capacitor?.Plugins?.CarambaPlayer
  console.log('[CarambaPlayer probe] plugins=', Object.keys(window.Capacitor?.Plugins ?? {}))
  console.log('[CarambaPlayer probe] CarambaPlayer present?', has)
  if (!has) return false
  try {
    const plugin = window.Capacitor.Plugins.CarambaPlayer
    if (typeof plugin.isAvailable !== 'function') {
      console.log('[CarambaPlayer probe] no isAvailable method on plugin')
      return false
    }
    const { available } = await plugin.isAvailable()
    console.log('[CarambaPlayer probe] isAvailable returned', available)
    return !!available
  } catch (err) {
    console.log('[CarambaPlayer probe] isAvailable threw:', err?.message || err)
    return false
  }
}

export default function App() {
  const [apiUrl, setApiUrl] = useState(null)
  const [isLoading, setIsLoading] = useState(isAndroidTV)
  const [hasNativePlayer, setHasNativePlayer] = useState(false)

  // Load configurable API URL on Android TV
  useEffect(() => {
    if (!isAndroidTV) {
      setIsLoading(false)
      return
    }

    loadApiUrl()
    probeNativePlayer().then(setHasNativePlayer)
  }, [])

  const loadApiUrl = async () => {
    try {
      // Try Capacitor Preferences
      if (window.Capacitor?.Plugins?.Preferences) {
        const { value } = await window.Capacitor.Plugins.Preferences.get({
          key: 'caramba_api_url'
        })
        if (value) {
          setApiUrl(value)
          setIsLoading(false)
          return
        }
      }

      // Fallback to localhost
      setApiUrl('http://localhost:3001')
    } catch (error) {
      console.warn('Failed to load API URL:', error)
      setApiUrl('http://localhost:3001')
    } finally {
      setIsLoading(false)
    }
  }

  const handleApiUrlChange = async (newUrl) => {
    if (!newUrl) return

    try {
      // Save to Capacitor if available
      if (window.Capacitor?.Plugins?.Preferences) {
        await window.Capacitor.Plugins.Preferences.set({
          key: 'caramba_api_url',
          value: newUrl
        })
      }
      setApiUrl(newUrl)
      return true
    } catch (error) {
      console.error('Failed to save API URL:', error)
      return false
    }
  }

  // Use configurable URL on Android TV, otherwise use environment default
  const apiBase = isAndroidTV && apiUrl ? apiUrl : (import.meta.env.VITE_API_BASE || '')
  
  const adapter = useMemo(() => createHttpAdapter(apiBase), [apiBase])
  const capabilities = useMemo(
    () => isAndroidTV
      ? { ...androidTvCapabilitiesBase, hasNativePlayer }
      : { ...webCapabilities, hasNativePlayer: false },
    [hasNativePlayer]
  )

  if (isLoading) {
    return (
      <div style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100vh',
        background: '#000',
        color: '#fff',
        fontSize: '24px'
      }}>
        Loading...
      </div>
    )
  }

  return (
    <ApiProvider adapter={adapter} capabilities={capabilities}>
      <ToastProvider>
        <PlayerProvider>
          <BrowserRouter>
            <Routes>
              <Route path="/" element={<Shows />} />
              <Route path="/shows/:slug" element={<Show />} />
              <Route path="/movies" element={<Movies />} />
              <Route path="/movies/:slug" element={<MovieShow />} />
              <Route path="/settings" element={
                <Settings 
                  isWebMode={!isAndroidTV}
                  onApiUrlChange={isAndroidTV ? handleApiUrlChange : undefined}
                  apiUrl={isAndroidTV ? apiUrl : undefined}
                />
              } />
            </Routes>
          </BrowserRouter>
          <VideoPlayer />
          <ToastContainer />
        </PlayerProvider>
      </ToastProvider>
    </ApiProvider>
  )
}
