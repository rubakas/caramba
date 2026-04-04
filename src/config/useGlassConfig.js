import { lip, convex, concave, convexCircle } from '@hashintel/refractive'
import glassConfig from './glass.json'

const SURFACE_FNS = { lip, convex, concave, convexCircle }

const DEFAULTABLE_KEYS = ['blur', 'bezelWidth', 'glassThickness', 'specularOpacity', 'refractiveIndex', 'bezelHeightFn']

/**
 * Returns the resolved refraction prop for a given specimen ID.
 * Merges glass.json "defaults" with per-specimen overrides.
 * Converts the bezelHeightFn string to the actual function reference.
 */
export function useGlassConfig(id) {
  const defaults = glassConfig.defaults || {}
  const raw = glassConfig[id]
  if (!raw) {
    console.warn(`[useGlassConfig] Unknown specimen id: "${id}"`)
    return { radius: 0, blur: 0 }
  }
  const merged = { ...defaults, ...raw }
  return {
    radius: merged.radius,
    blur: merged.blur,
    bezelWidth: merged.bezelWidth,
    glassThickness: merged.glassThickness,
    specularOpacity: merged.specularOpacity,
    refractiveIndex: merged.refractiveIndex,
    bezelHeightFn: SURFACE_FNS[merged.bezelHeightFn] || convex,
  }
}

/**
 * Returns the raw defaults from glass.json (the shared base values).
 */
export function getGlassBaseDefaults() {
  return { ...(glassConfig.defaults || {}) }
}

/**
 * Returns the resolved (merged) raw config for a specimen (strings, not functions).
 * Useful for the playground to read the effective values.
 */
export function getGlassResolved(id) {
  const defaults = glassConfig.defaults || {}
  const raw = glassConfig[id]
  if (!raw) return null
  return { ...defaults, ...raw }
}

/**
 * Returns the per-specimen overrides only (what's stored in glass.json minus defaults).
 */
export function getGlassOverrides(id) {
  return glassConfig[id] ? { ...glassConfig[id] } : null
}

/**
 * Returns all resolved configs (defaults merged into each specimen).
 * Useful for the playground.
 */
export function getAllGlassDefaults() {
  const defaults = glassConfig.defaults || {}
  const result = {}
  for (const [id, raw] of Object.entries(glassConfig)) {
    if (id === 'defaults') continue
    result[id] = { ...defaults, ...raw }
  }
  return result
}

/**
 * Returns the list of keys that can be inherited from defaults (everything except radius).
 */
export { DEFAULTABLE_KEYS }
