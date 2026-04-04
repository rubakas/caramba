import { createContext, useContext, useState, useCallback, useRef, useMemo } from 'react'

const ToastContext = createContext(null)

let toastId = 0

const MAX_TOASTS = 5

export function ToastProvider({ children }) {
  const [toasts, setToasts] = useState([])
  const timersRef = useRef({})

  const dismiss = useCallback((id) => {
    // Mark as fading out, then remove after animation
    setToasts(prev => prev.map(t => t.id === id ? { ...t, fading: true } : t))
    clearTimeout(timersRef.current[id])
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id))
      delete timersRef.current[id]
    }, 400)
  }, [])

  const showToast = useCallback((message, { type = 'error', duration = 5000 } = {}) => {
    const id = ++toastId
    setToasts(prev => {
      const next = [...prev, { id, message, type, fading: false }]
      // Cap the number of visible toasts — dismiss the oldest if over limit
      if (next.length > MAX_TOASTS) {
        const excess = next.slice(0, next.length - MAX_TOASTS)
        for (const t of excess) {
          clearTimeout(timersRef.current[t.id])
          delete timersRef.current[t.id]
        }
        return next.slice(next.length - MAX_TOASTS)
      }
      return next
    })

    // Auto-dismiss after duration
    timersRef.current[id] = setTimeout(() => dismiss(id), duration)

    return id
  }, [dismiss])

  const contextValue = useMemo(() => ({ toasts, showToast, dismiss }), [toasts, showToast, dismiss])

  return (
    <ToastContext.Provider value={contextValue}>
      {children}
    </ToastContext.Provider>
  )
}

export function useToast() {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToast must be used within ToastProvider')
  return ctx
}
