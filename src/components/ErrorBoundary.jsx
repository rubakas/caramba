import { Component } from 'react'

export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props)
    this.state = { hasError: false, error: null }
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error }
  }

  componentDidCatch(error, errorInfo) {
    console.error('[ErrorBoundary] Uncaught render error:', error, errorInfo)
  }

  handleReload = () => {
    window.location.reload()
  }

  handleDismiss = () => {
    this.setState({ hasError: false, error: null })
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          height: '100vh',
          background: '#1a1a1a',
          color: '#e0e0e0',
          fontFamily: 'system-ui, -apple-system, sans-serif',
          padding: '2rem',
          textAlign: 'center',
        }}>
          <h1 style={{ fontSize: '1.5rem', marginBottom: '0.5rem', color: '#fff' }}>
            Something went wrong
          </h1>
          <p style={{ fontSize: '0.9rem', color: '#999', marginBottom: '1.5rem', maxWidth: '400px' }}>
            The app encountered an unexpected error. You can try dismissing the error or reloading the app.
          </p>
          {this.state.error && (
            <pre style={{
              fontSize: '0.75rem',
              color: '#e57373',
              background: '#2a2a2a',
              padding: '0.75rem 1rem',
              borderRadius: '6px',
              maxWidth: '500px',
              overflow: 'auto',
              marginBottom: '1.5rem',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}>
              {String(this.state.error)}
            </pre>
          )}
          <div style={{ display: 'flex', gap: '0.75rem' }}>
            <button
              onClick={this.handleDismiss}
              style={{
                padding: '0.5rem 1.25rem',
                borderRadius: '6px',
                border: '1px solid #555',
                background: 'transparent',
                color: '#e0e0e0',
                cursor: 'pointer',
                fontSize: '0.85rem',
              }}
            >
              Dismiss
            </button>
            <button
              onClick={this.handleReload}
              style={{
                padding: '0.5rem 1.25rem',
                borderRadius: '6px',
                border: 'none',
                background: '#4a90d9',
                color: '#fff',
                cursor: 'pointer',
                fontSize: '0.85rem',
              }}
            >
              Reload App
            </button>
          </div>
        </div>
      )
    }

    return this.props.children
  }
}
