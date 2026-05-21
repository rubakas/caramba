import { useEffect, useState, useCallback } from 'react'

// localStorage-backed toggle for "Learning mode". When enabled, the
// Navbar surfaces a Learn link and the `/learn` route becomes visible.
// Default is off — most users come to Caramba to watch, not to study.
// Cross-syncs across tabs via the `storage` event.
const STORAGE_KEY = 'caramba_learning_mode'

function readStored() {
  if (typeof localStorage === 'undefined') return null
  try { return localStorage.getItem(STORAGE_KEY) } catch { return null }
}

function currentEnabled() {
  return readStored() === 'true'
}

export function useLearningMode() {
  const [enabled, setEnabledState] = useState(currentEnabled)

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
