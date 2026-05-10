import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { useMemo, useState, useEffect } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createHttpAdapter, httpCapabilities } from '@caramba/ui/adapters/http'
import { buildBrowserProfile, buildAndroidTvProfile } from '@caramba/ui/adapters/device-profile'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Shows from '@caramba/ui/pages/Shows'
import Show from '@caramba/ui/pages/Show'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Settings from '@caramba/ui/pages/Settings'
import Admin from '@caramba/ui/pages/Admin'
import UpdatePrompt from '@caramba/ui/components/UpdatePrompt'

// Check if running in Capacitor (Android/iOS native app)
const isCapacitor = typeof window !== 'undefined' && window.Capacitor && window.Capacitor.isNativePlatform === true

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

// One-shot probe for the native player Capacitor plugin (Android TV builds
// only). When present, VideoPlayer.jsx skips the WebView <video>/hls.js
// path and lets ExoPlayer handle decode natively — bypasses all the MSE
// codec limitations (HEVC Main 10, AC3, DTS, TrueHD) that force
// audio_transcode/full_transcode on Android.
async function probeNativePlayer() {
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
  const [isLoading, setIsLoading] = useState(true)
  const [isNativeApp, setIsNativeApp] = useState(false)
  const [hasNativePlayer, setHasNativePlayer] = useState(false)

  // Load configurable API URL
  useEffect(() => {
    checkPlatformAndLoadUrl()
    probeNativePlayer().then(setHasNativePlayer)
  }, [])

  // Add tv-mode class to body when running on Android TV
  useEffect(() => {
    if (isNativeApp) {
      document.body.classList.add('tv-mode')
      console.log('[App] Added tv-mode class to body')
    }
    return () => {
      document.body.classList.remove('tv-mode')
    }
  }, [isNativeApp])

  const checkPlatformAndLoadUrl = async () => {
    try {
      // Check if Capacitor Preferences plugin is available
      const hasCapacitor = typeof window !== 'undefined' && 
                           window.Capacitor?.Plugins?.Preferences

      if (hasCapacitor) {
        setIsNativeApp(true)
        
        // Try to load saved API URL
        const { value } = await window.Capacitor.Plugins.Preferences.get({
          key: 'caramba_api_url'
        })
        
        if (value) {
          console.log('Loaded API URL from preferences:', value)
          setApiUrl(value)
        } else {
          // No URL saved yet, use empty (will show setup needed)
          console.log('No API URL saved, using default')
          setApiUrl('')
        }
      } else {
        // Web mode - use environment variable or empty
        setIsNativeApp(false)
        setApiUrl(import.meta.env.VITE_API_BASE || '')
      }
    } catch (error) {
      console.error('Failed to load API URL:', error)
      setApiUrl('')
    } finally {
      setIsLoading(false)
    }
  }

  const handleApiUrlChange = async (newUrl) => {
    if (!newUrl) return false

    try {
      // Save to Capacitor Preferences
      if (window.Capacitor?.Plugins?.Preferences) {
        await window.Capacitor.Plugins.Preferences.set({
          key: 'caramba_api_url',
          value: newUrl
        })
        console.log('Saved API URL:', newUrl)
      }
      
      // Update state and force reload to apply new URL
      setApiUrl(newUrl)
      
      // Force reload the app to recreate adapter with new URL
      setTimeout(() => {
        window.location.reload()
      }, 500)
      
      return true
    } catch (error) {
      console.error('Failed to save API URL:', error)
      return false
    }
  }

  const capabilities = useMemo(
    () => isNativeApp
      ? { ...androidTvCapabilitiesBase, hasNativePlayer }
      : { ...webCapabilities, hasNativePlayer: false },
    [isNativeApp, hasNativePlayer]
  )
  
  // Create adapter with current API URL. When the native ExoPlayer plugin
  // is registered, send the Android TV / ExoPlayer profile so the server
  // picks direct_stream for HEVC HDR / AC3 / EAC3 sources instead of
  // tonemap-transcoding them — those codecs hit ExoPlayer's hardware
  // decoder directly via the native PlayerActivity.
  const adapter = useMemo(() => {
    console.log('Creating HTTP adapter with base URL:', apiUrl, 'nativePlayer:', hasNativePlayer)
    const buildProfile = hasNativePlayer ? buildAndroidTvProfile : buildBrowserProfile
    const httpAdapter = createHttpAdapter(apiUrl || '', { buildProfile })
    // Expose adapter as window.api for components that access it directly (e.g., UpdatePrompt)
    if (isNativeApp) {
      window.api = httpAdapter
    }
    return httpAdapter
  }, [apiUrl, isNativeApp, hasNativePlayer])

  if (isLoading) {
    // For native apps, show minimal loading state (no text to avoid double loading)
    // The page-level loading will show instead
    if (isNativeApp || window.Capacitor?.Plugins?.Preferences) {
      return (
        <div style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          height: '100vh',
          background: '#000',
        }} />
      )
    }
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

  // Show setup screen if no API URL configured on native app
  if (isNativeApp && !apiUrl) {
    return (
      <div style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        height: '100vh',
        background: '#000',
        color: '#fff',
        padding: '40px',
        textAlign: 'center'
      }}>
        <h1 style={{ fontSize: '32px', marginBottom: '16px' }}>Welcome to Caramba</h1>
        <p style={{ fontSize: '18px', color: '#aaa', marginBottom: '32px' }}>
          Looking for a Caramba server on your network…
        </p>
        <Settings 
          isWebMode={false}
          onApiUrlChange={handleApiUrlChange}
          apiUrl={apiUrl}
          hideNavbar={true}
        />
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
                  isWebMode={!isNativeApp}
                  onApiUrlChange={isNativeApp ? handleApiUrlChange : undefined}
                  apiUrl={isNativeApp ? apiUrl : undefined}
                />
              } />
              <Route path="/admin" element={<Admin />} />
            </Routes>
          </BrowserRouter>
          <VideoPlayer />
          <ToastContainer />
          {/* Show update prompt on Android TV (Capacitor) */}
          {isNativeApp && <UpdatePrompt />}
        </PlayerProvider>
      </ToastProvider>
    </ApiProvider>
  )
}
