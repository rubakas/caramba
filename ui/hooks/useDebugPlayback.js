import { useEffect, useState, useCallback } from 'react'

// localStorage-backed toggle for the playback debug overlay (strategy
// pill + source codec/res/bitrate/HDR/audio summary). Default mirrors
// `import.meta.env.DEV` so dev builds keep the pill visible without
// any setup, while production builds stay clean unless the user opts
// in from Settings. The setting cross-syncs across tabs via the
// `storage` event so toggling it in Settings reflects in an open
// player overlay live.
const STORAGE_KEY = 'caramba_debug_playback'

function readStored() {
  if (typeof localStorage === 'undefined') return null
  try { return localStorage.getItem(STORAGE_KEY) } catch { return null }
}

function defaultEnabled() {
  return !!import.meta.env.DEV
}

function currentEnabled() {
  const v = readStored()
  if (v === 'true') return true
  if (v === 'false') return false
  return defaultEnabled()
}

export function useDebugPlayback() {
  const [enabled, setEnabledState] = useState(currentEnabled)

  // Sync from other tabs / from direct localStorage edits.
  useEffect(() => {
    const onStorage = (e) => {
      if (e.key !== STORAGE_KEY) return
      setEnabledState(currentEnabled())
    }
    window.addEventListener('storage', onStorage)
    return () => window.removeEventListener('storage', onStorage)
  }, [])

  const setEnabled = useCallback((next) => {
    try { localStorage.setItem(STORAGE_KEY, next ? 'true' : 'false') } catch {}
    setEnabledState(!!next)
  }, [])

  return [enabled, setEnabled]
}
