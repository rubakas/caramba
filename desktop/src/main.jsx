import React from 'react'
import ReactDOM from 'react-dom/client'
import * as Sentry from '@sentry/electron/renderer'
import App from './App'
import ErrorBoundary from '@caramba/ui/components/ErrorBoundary'
import { sentryInit } from '@caramba/ui/sentry/init'
import '@caramba/ui/styles/app.css'

sentryInit({
  Sentry,
  dsn: import.meta.env.VITE_SENTRY_DSN,
  platform: 'desktop-renderer',
  release: __SENTRY_RELEASE__,
  isDev: import.meta.env.DEV,
})

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
)
