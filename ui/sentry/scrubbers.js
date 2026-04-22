const MEDIA_EXT = '(mkv|mp4|avi|webm|m4v|mov|mp3|flac|srt|vtt|ass)'
const HOME_PATH_RE = /\/(Users|home)\/[^/"'`<>]+?\//g
const MEDIA_FILE_RE = new RegExp(`[\\w.\\-]+\\.${MEDIA_EXT}`, 'gi')
const NUMERIC_ID_RE = /\/\d+(?=\/|$|\?)/g
const UUID_RE = /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=\/|$|\?)/gi
const SEARCH_TERM_RE = /(Failed to fetch (?:TVMaze|IMDb)[^:]*:\s*)(.+)/g

export function scrubString(input) {
  if (typeof input !== 'string') return input
  return input
    .replace(HOME_PATH_RE, '~/')
    .replace(MEDIA_FILE_RE, (match) => {
      const dot = match.lastIndexOf('.')
      return `*${match.slice(dot).toLowerCase()}`
    })
    .replace(SEARCH_TERM_RE, '$1<redacted>')
}

export function scrubUrl(input) {
  if (typeof input !== 'string') return input
  const [base] = input.split('?')
  return base
    .replace(UUID_RE, '/:id')
    .replace(NUMERIC_ID_RE, '/:id')
}

export function beforeSend(event) {
  if (!event) return event
  if (event.message) event.message = scrubString(event.message)
  if (event.request) {
    if (event.request.url) event.request.url = scrubUrl(event.request.url)
    if (event.request.query_string) event.request.query_string = ''
  }
  const values = event.exception?.values
  if (Array.isArray(values)) {
    for (const v of values) {
      if (v.value) v.value = scrubString(v.value)
      const frames = v.stacktrace?.frames
      if (Array.isArray(frames)) {
        for (const f of frames) {
          if (f.filename) f.filename = scrubString(f.filename)
          if (f.abs_path) f.abs_path = scrubString(f.abs_path)
        }
      }
    }
  }
  if (event.user?.username) delete event.user.username
  return event
}

export function beforeBreadcrumb(crumb) {
  if (!crumb) return crumb
  if (crumb.message) crumb.message = scrubString(scrubUrl(crumb.message))
  if (crumb.data) {
    if (crumb.data.url) crumb.data.url = scrubUrl(crumb.data.url)
    if (crumb.data.to) crumb.data.to = scrubUrl(crumb.data.to)
    if (crumb.data.from) crumb.data.from = scrubUrl(crumb.data.from)
  }
  return crumb
}
