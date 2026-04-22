const Sentry = require('@sentry/electron/main')
const path = require('path')
const fs = require('fs')

function loadDotenv() {
  const envPath = path.join(__dirname, '..', '.env')
  try {
    const raw = fs.readFileSync(envPath, 'utf8')
    for (const line of raw.split('\n')) {
      const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/)
      if (m && !process.env[m[1]]) process.env[m[1]] = m[2]
    }
  } catch {
    // .env missing in packaged builds; env vars are expected to be set elsewhere.
  }
}

loadDotenv()

const dsn = process.env.SENTRY_DSN
if (dsn) {
  Sentry.init({
    dsn,
    release: process.env.SENTRY_RELEASE || 'dev',
    environment: process.env.NODE_ENV === 'development' ? 'development' : 'production',
    sendDefaultPii: false,
    tracesSampleRate: 0.2,
    initialScope: { tags: { platform: 'desktop-main' } },
  })
} else {
  console.info('[sentry/main] SENTRY_DSN not set, skipping init')
}

module.exports = Sentry
