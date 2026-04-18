import { BrowserRouter, Routes, Route } from 'react-router-dom'
import { useMemo, useState, useEffect } from 'react'
import { ApiProvider } from '@caramba/ui/context/ApiContext'
import { createHttpAdapter, httpCapabilities } from '@caramba/ui/adapters/http'
import { ToastProvider } from '@caramba/ui/context/ToastContext'
import { PlayerProvider } from '@caramba/ui/context/PlayerContext'
import ToastContainer from '@caramba/ui/components/ToastContainer'
import VideoPlayer from '@caramba/ui/components/VideoPlayer'
import Library from '@caramba/ui/pages/Library'
import SeriesShow from '@caramba/ui/pages/SeriesShow'
import Movies from '@caramba/ui/pages/Movies'
import MovieShow from '@caramba/ui/pages/MovieShow'
import Discover from '@caramba/ui/pages/Discover'
import History from '@caramba/ui/pages/History'
import Settings from '@caramba/ui/pages/Settings'
import { Capacitor } from '@capacitor/core'

const isAndroidTV = Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'android'

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
  const [isLoading, setIsLoading] = useState(isAndroidTV)

  // Load configurable API URL on Android TV
  useEffect(() => {
    if (!isAndroidTV) {
      setIsLoading(false)
      return
    }

    loadApiUrl()
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
  const capabilities = isAndroidTV ? androidTvCapabilities : webCapabilities

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
              <Route path="/" element={<Library />} />
              <Route path="/series/:slug" element={<SeriesShow />} />
              <Route path="/movies" element={<Movies />} />
              <Route path="/movies/:slug" element={<MovieShow />} />
              <Route path="/discover" element={<Discover />} />
              <Route path="/history" element={<History />} />
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
