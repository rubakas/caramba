/**
 * Safari-aware and Android TV-aware refractive wrapper.
 *
 * @hashintel/refractive applies backdrop-filter via SVG filter references
 * (backdrop-filter: url(#svg-id)), which Safari does not support.
 * On Safari we render a plain element with CSS backdrop-filter: blur(Npx)
 * as a fallback. On other browsers we pass through to the real library.
 *
 * On Android TV (Capacitor native app), we disable blur entirely for
 * performance reasons - the Chromecast GPU can't handle it well.
 *
 * Surface-equation re-exports (lip, convex, etc.) are always from the real lib.
 */
import { createElement, forwardRef } from 'react'
import {
  refractive as realRefractive,
  lip,
  convex,
  concave,
  convexCircle,
} from '@hashintel/refractive'

const isSafari =
  typeof navigator !== 'undefined' &&
  /^((?!chrome|android).)*safari/i.test(navigator.userAgent)

// Detect Android TV (Capacitor native app)
const isAndroidTV =
  typeof window !== 'undefined' &&
  window.Capacitor?.isNativePlatform?.() === true

/**
 * Build a fallback component for a given HTML tag.
 * Strips the `refraction` prop and applies CSS blur + border-radius instead.
 * On Android TV, skip blur entirely for performance.
 */
function makeFallback(tag) {
  return forwardRef(function RefractFallback({ refraction, ...rest }, ref) {
    const blurPx = isAndroidTV ? 0 : (refraction?.blur ?? 0)
    const radius = refraction?.radius ?? 0
    const style = {
      ...rest.style,
      WebkitBackdropFilter: blurPx ? `blur(${blurPx}px)` : undefined,
      backdropFilter: blurPx ? `blur(${blurPx}px)` : undefined,
      borderRadius: radius,
      // On Android TV, use solid background instead of glass effect
      ...(isAndroidTV && {
        background: 'rgba(28, 28, 30, 0.95)',
      }),
    }
    return createElement(tag, { ...rest, ref, style })
  })
}

const fallbackCache = new Map()

// Use fallback on Safari OR Android TV
const useFallback = isSafari || isAndroidTV

const refractive = useFallback
  ? new Proxy(makeFallback, {
      get(_target, tag) {
        if (fallbackCache.has(tag)) return fallbackCache.get(tag)
        const comp = makeFallback(tag)
        fallbackCache.set(tag, comp)
        return comp
      },
      apply(_target, _this, args) {
        // refractive(CustomComponent) call – wrap it
        const Wrapped = args[0]
        return forwardRef(function RefractFallbackCustom(
          { refraction, ...rest },
          ref,
        ) {
          const blurPx = isAndroidTV ? 0 : (refraction?.blur ?? 0)
          const radius = refraction?.radius ?? 0
          const style = {
            ...rest.style,
            WebkitBackdropFilter: blurPx ? `blur(${blurPx}px)` : undefined,
            backdropFilter: blurPx ? `blur(${blurPx}px)` : undefined,
            borderRadius: radius,
            ...(isAndroidTV && {
              background: 'rgba(28, 28, 30, 0.95)',
            }),
          }
          return createElement(Wrapped, { ...rest, ref, style })
        })
      },
    })
  : realRefractive

export { refractive, lip, convex, concave, convexCircle }
