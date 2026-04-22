import { beforeSend, beforeBreadcrumb } from './scrubbers.js'
import { reactRouterV7Integration } from './router.js'

/**
 * Platform-agnostic Sentry init. Caller passes the Sentry SDK object from
 * whichever package they use (@sentry/react, @sentry/electron/renderer,
 * @sentry/capacitor). Safe to call at most once per process.
 *
 * @param {object} opts
 * @param {object} opts.Sentry        The Sentry SDK object
 * @param {string} opts.dsn           DSN from env; falsy → no-op
 * @param {string} opts.platform      One of: web | desktop-renderer | android-tv
 * @param {string} opts.release       Release identifier (e.g. "caramba@v1.3.7")
 * @param {number} [opts.tracesSampleRate]
 * @param {boolean} [opts.enableInDev]
 * @param {boolean} [opts.isDev]
 */
export function sentryInit(opts) {
  const { Sentry, dsn, platform, release, tracesSampleRate, isDev } = opts
  if (!dsn) {
    console.info('[sentry] no DSN provided, skipping init')
    return
  }
  if (isDev && !opts.enableInDev) {
    console.info('[sentry] dev mode — Sentry disabled; pass enableInDev:true to override')
    return
  }
  const integrations = []
  if (typeof Sentry.browserTracingIntegration === 'function') {
    integrations.push(Sentry.browserTracingIntegration())
  }
  const routerIntegration = reactRouterV7Integration(Sentry)
  if (routerIntegration) integrations.push(routerIntegration)

  Sentry.init({
    dsn,
    release,
    environment: isDev ? 'development' : 'production',
    sendDefaultPii: false,
    tracesSampleRate: tracesSampleRate ?? (isDev ? 1.0 : 0.2),
    integrations,
    beforeSend,
    beforeBreadcrumb,
  })
  Sentry.setTag('platform', platform)

  if (typeof window !== 'undefined') {
    window.__SENTRY__ = Sentry
  }
}
