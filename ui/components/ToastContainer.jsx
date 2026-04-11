import { refractive } from '../config/refractive'
import { useToast } from '../context/ToastContext'
import { useGlassConfig } from '../config/useGlassConfig'

export default function ToastContainer() {
  const { toasts, dismiss } = useToast()
  const toastGlass = useGlassConfig('toast')

  if (toasts.length === 0) return null

  return (
    <div className="toast-container">
      {toasts.map((toast) => (
        <refractive.div
          key={toast.id}
          className={`toast toast--${toast.type}${toast.fading ? ' fade-out' : ''}`}
          onClick={() => dismiss(toast.id)}
          refraction={toastGlass}
        >
          <span className="toast-message">{toast.message}</span>
        </refractive.div>
      ))}
    </div>
  )
}
