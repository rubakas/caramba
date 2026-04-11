import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import ErrorBoundary from '@caramba/ui/components/ErrorBoundary'
import '@caramba/ui/styles/app.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
)
