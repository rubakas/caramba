import { createContext, useContext, useMemo } from 'react'

const ApiContext = createContext(null)

/**
 * Provides API adapter and platform capabilities to all UI components.
 *
 * @param {Object} props
 * @param {Object} props.adapter - Object with all API methods (local or HTTP)
 * @param {Object} props.capabilities - Platform capabilities flags
 * @param {boolean} props.capabilities.canPlay - Can play media (local ffmpeg/VLC)
 * @param {boolean} props.capabilities.canDownload - Can download media files
 * @param {boolean} props.capabilities.canAdd - Can add new series/movies (folder/file picker)
 * @param {boolean} props.capabilities.canManage - Can scan/refresh/remove/relocate
 * @param {boolean} props.capabilities.canOpenExternal - Can open in VLC/default player
 * @param {boolean} props.capabilities.hasNowPlaying - Show NowPlaying bar
 * @param {boolean} props.capabilities.hasSettings - Show Settings page
 * @param {boolean} props.capabilities.canAdmin - Show Admin page (server-side library admin)
 */
export function ApiProvider({ adapter, capabilities, children }) {
  const value = useMemo(() => ({ api: adapter, capabilities }), [adapter, capabilities])
  return <ApiContext.Provider value={value}>{children}</ApiContext.Provider>
}

export function useApi() {
  const ctx = useContext(ApiContext)
  if (!ctx) throw new Error('useApi must be used within ApiProvider')
  return ctx.api
}

export function useCapabilities() {
  const ctx = useContext(ApiContext)
  if (!ctx) throw new Error('useCapabilities must be used within ApiProvider')
  return ctx.capabilities
}
