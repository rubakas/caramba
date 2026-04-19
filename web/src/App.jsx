import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { useMemo, useState, useEffect } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createHttpAdapter, httpCapabilities } from '@caramba/ui/adapters/http'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Shows from '@caramba/ui/pages/Shows'
import SeriesShow from '@caramba/ui/pages/SeriesShow'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Settings from '@caramba/ui/pages/Settings'
import Admin from '@caramba/ui/pages/Admin'
import UpdatePrompt from '@caramba/ui/components/UpdatePrompt'

// Check if running in Capacitor (Android/iOS native app)
const isCapacitor = typeof window !== 'undefined' && window.Capacitor && window.Capacitor.isNativePlatform === true

// Android TV capabilities - show Settings with API URL config, no file management
const androidTvCapabilities = {
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

export default function App() {
  const [apiUrl, setApiUrl] = useState(null)
  const [isLoading, setIsLoading] = useState(true)
  const [isNativeApp, setIsNativeApp] = useState(false)

  // Load configurable API URL
  useEffect(() => {
    checkPlatformAndLoadUrl()
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

  const capabilities = isNativeApp ? androidTvCapabilities : webCapabilities
  
  // Create adapter with current API URL
  const adapter = useMemo(() => {
    console.log('Creating HTTP adapter with base URL:', apiUrl)
    const httpAdapter = createHttpAdapter(apiUrl || '')
    // Expose adapter as window.api for components that access it directly (e.g., UpdatePrompt)
    if (isNativeApp) {
      window.api = httpAdapter
    }
    return httpAdapter
  }, [apiUrl, isNativeApp])

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
              <Route path="/series/:slug" element={<SeriesShow />} />
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
