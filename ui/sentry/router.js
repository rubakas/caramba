import { useEffect } from 'react'
import {
  useLocation,
  useNavigationType,
  createRoutesFromChildren,
  matchRoutes,
} from 'react-router-dom'

export function reactRouterV7Integration(Sentry) {
  if (typeof Sentry.reactRouterV7BrowserTracingIntegration !== 'function') {
    return null
  }
  return Sentry.reactRouterV7BrowserTracingIntegration({
    useEffect,
    useLocation,
    useNavigationType,
    createRoutesFromChildren,
    matchRoutes,
  })
}
