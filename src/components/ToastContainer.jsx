import { useToast } from '../context/ToastContext'

export default function ToastContainer() {
  const { toasts, dismiss } = useToast()

  if (toasts.length === 0) return null

  return (
    <div className="toast-container">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`toast toast--${toast.type}${toast.fading ? ' fade-out' : ''}`}
          onClick={() => dismiss(toast.id)}
        >
          <span className="toast-icon">
            {toast.type === 'error' ? '\u2718' : toast.type === 'success' ? '\u2713' : '\u24D8'}
          </span>
          <span className="toast-message">{toast.message}</span>
        </div>
      ))}
    </div>
  )
}
