import { useState, useEffect, useRef } from 'react'

export function usePlayback() {
  const [playback, setPlayback] = useState(null)
  const intervalRef = useRef(null)
  const wasPlayingRef = useRef(false)

  useEffect(() => {
    const poll = async () => {
      try {
        const status = await window.api.getPlaybackStatus()
        setPlayback(status)

        if (status?.playing) {
          wasPlayingRef.current = true
        } else if (wasPlayingRef.current) {
          // Playback just stopped — trigger a page data refresh
          wasPlayingRef.current = false
          // Dispatch a custom event that pages can listen for
          window.dispatchEvent(new Event('playback-stopped'))
        }
      } catch {
        setPlayback(null)
      }
    }

    poll()
    intervalRef.current = setInterval(poll, 3000)

    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current)
    }
  }, [])

  return playback
}
