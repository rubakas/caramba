// Shared utility functions

export function formatTime(seconds) {
  if (!seconds || seconds <= 0) return '0:00'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (h > 0) {
    return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`
  }
  return `${m}:${s.toString().padStart(2, '0')}`
}

export function progressPercent(progress, duration) {
  if (!progress || !duration || duration === 0) return 0
  return Math.min(Math.round((progress / duration) * 100), 100)
}

export function isInProgress(item) {
  return item.progress_seconds > 0 &&
    item.duration_seconds > 0 &&
    (item.progress_seconds / item.duration_seconds) < 0.9
}

export function truncate(str, length = 120) {
  if (!str) return ''
  if (str.length <= length) return str
  return str.slice(0, length).trimEnd() + '...'
}

export function genresList(genres) {
  if (!genres) return []
  try {
    const parsed = JSON.parse(genres)
    if (Array.isArray(parsed)) return parsed
  } catch {
    // Not JSON, try comma-separated
  }
  return genres.split(',').map(g => g.trim()).filter(Boolean)
}

export function premiereYear(premiered) {
  if (!premiered) return null
  return premiered.slice(0, 4)
}

export function runtimeDisplay(runtimeSeconds) {
  if (!runtimeSeconds) return null
  const mins = Math.round(runtimeSeconds / 60)
  if (mins >= 60) {
    const h = Math.floor(mins / 60)
    const m = mins % 60
    return m > 0 ? `${h}h ${m}m` : `${h}h`
  }
  return `${mins}m`
}

export function statusClass(status) {
  if (!status) return ''
  return status.toLowerCase().replace(/\s+/g, '-')
}
