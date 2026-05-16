/**
 * Normalises Capacitor's `plugin.addListener(event, cb)` return value.
 *
 * Capacitor 6+ resolves a `PluginListenerHandle` from a Promise; older
 * builds return the handle synchronously. CarambaPlayer on the Android TV
 * build takes the sync path, which is why `addListener(...).then(...)`
 * blew up at unmount with "X?.then is not a function".
 *
 * Returns a stable unsubscribe function that handles the "unmount fires
 * before the Promise resolved" race by removing on arrival.
 */
export function subscribeCapacitorListener(plugin, event, handler) {
  const result = plugin?.addListener?.(event, handler)
  if (!result) return () => {}
  let handle = null
  let removed = false
  if (typeof result.then === 'function') {
    result.then(h => {
      if (removed) h?.remove?.()
      else handle = h
    }).catch(() => {})
  } else {
    handle = result
  }
  return () => {
    removed = true
    handle?.remove?.()
  }
}
