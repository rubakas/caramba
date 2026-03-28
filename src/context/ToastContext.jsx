import { createContext, useContext, useState, useCallback, useRef } from 'react'

const ToastContext = createContext(null)

let toastId = 0

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
    setToasts(prev => [...prev, { id, message, type, fading: false }])

    // Auto-dismiss after duration
    timersRef.current[id] = setTimeout(() => dismiss(id), duration)

    return id
  }, [dismiss])

  return (
    <ToastContext.Provider value={{ toasts, showToast, dismiss }}>
      {children}
    </ToastContext.Provider>
  )
}

export function useToast() {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToast must be used within ToastProvider')
  return ctx
}
