import { useState, useEffect } from 'react'

/**
 * Hook for managing configurable API URL (Android TV / Desktop style)
 * On Android: Uses Capacitor Preferences plugin
 * On Web: Uses localStorage
 * On Desktop: Managed via Electron IPC
 */
export function useConfigurableApiUrl() {
  const [apiUrl, setApiUrl] = useState(null)
  const [isLoading, setIsLoading] = useState(true)

  // Initialize API URL from storage
  useEffect(() => {
    loadApiUrl()
  }, [])

  const loadApiUrl = async () => {
    try {
      // Try Capacitor (Android/iOS)
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

      // Fallback to localStorage
      const stored = localStorage.getItem('caramba_api_url')
      if (stored) {
        setApiUrl(stored)
      } else {
        // Default to localhost
        setApiUrl('http://localhost:3001')
      }
    } catch (error) {
      console.warn('Failed to load API URL:', error)
      setApiUrl('http://localhost:3001')
    } finally {
      setIsLoading(false)
    }
  }

  const updateApiUrl = async (newUrl) => {
    if (!newUrl) return

    try {
      // Validate URL format
      new URL(newUrl)
      
      // Save to Capacitor if available
      if (window.Capacitor?.Plugins?.Preferences) {
        await window.Capacitor.Plugins.Preferences.set({
          key: 'caramba_api_url',
          value: newUrl
        })
      }

      // Also save to localStorage as fallback
      localStorage.setItem('caramba_api_url', newUrl)
      
      setApiUrl(newUrl)
      return true
    } catch (error) {
      console.error('Invalid API URL:', error)
      return false
    }
  }

  return {
    apiUrl,
    isLoading,
    updateApiUrl,
    loadApiUrl
  }
}
