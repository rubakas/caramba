import { describe, it, expect } from 'vitest'
import { scrubString, scrubUrl, beforeSend, beforeBreadcrumb } from './scrubbers.js'

describe('scrubString', () => {
  it('collapses absolute user paths to ~/', () => {
    expect(scrubString('/Users/vladyslav/Movies/x.mkv')).toBe('~/Movies/*.mkv')
    expect(scrubString('/home/vlad/video.mp4')).toBe('~/*.mp4')
  })

  it('strips media filename stems, keeping extension', () => {
    expect(scrubString('Failed to transcode The.Sopranos.S01E03.mkv'))
      .toBe('Failed to transcode *.mkv')
    expect(scrubString('movie.MP4')).toBe('*.mp4')
  })

  it('is case-insensitive for media extensions', () => {
    expect(scrubString('/Users/a/x.MKV')).toBe('~/*.mkv')
  })

  it('redacts TVMaze/IMDb search terms', () => {
    expect(scrubString('Failed to fetch TVMaze: Sopranos'))
      .toBe('Failed to fetch TVMaze: <redacted>')
    expect(scrubString('Failed to fetch IMDb search: The Matrix'))
      .toBe('Failed to fetch IMDb search: <redacted>')
  })

  it('leaves non-sensitive strings unchanged', () => {
    expect(scrubString('ECONNREFUSED 127.0.0.1:3001'))
      .toBe('ECONNREFUSED 127.0.0.1:3001')
  })

  it('handles non-string input by returning it unchanged', () => {
    expect(scrubString(undefined)).toBe(undefined)
    expect(scrubString(null)).toBe(null)
    expect(scrubString(42)).toBe(42)
  })

  it('handles usernames with spaces', () => {
    expect(scrubString('/Users/Foo Bar/Movies/x.mkv')).toBe('~/Movies/*.mkv')
    expect(scrubString('/home/jane doe/video.mp4')).toBe('~/*.mp4')
  })
})

describe('scrubUrl', () => {
  it('replaces numeric id segments with :id', () => {
    expect(scrubUrl('/api/series/42/episodes/7'))
      .toBe('/api/series/:id/episodes/:id')
  })

  it('replaces UUID segments with :id', () => {
    expect(scrubUrl('/session/3f8e8a41-2b4c-4d5e-9f0a-1b2c3d4e5f6a/start'))
      .toBe('/session/:id/start')
  })

  it('strips query strings entirely', () => {
    expect(scrubUrl('/search?q=sopranos&page=2')).toBe('/search')
  })

  it('preserves non-id path segments', () => {
    expect(scrubUrl('/api/health')).toBe('/api/health')
  })

  it('handles absolute URLs', () => {
    expect(scrubUrl('http://localhost:3001/api/series/42?t=1'))
      .toBe('http://localhost:3001/api/series/:id')
  })

  it('handles non-string input by returning it unchanged', () => {
    expect(scrubUrl(undefined)).toBe(undefined)
    expect(scrubUrl(null)).toBe(null)
  })
})

describe('beforeSend', () => {
  it('scrubs message, exception value, stack filenames, request url', () => {
    const event = {
      message: 'Failed to transcode /Users/vladyslav/Movies/x.mkv',
      exception: {
        values: [
          {
            value: 'Cannot read /Users/vladyslav/a.mkv',
            stacktrace: {
              frames: [
                { filename: '/Users/vladyslav/code/caramba/web/src/App.jsx' },
              ],
            },
          },
        ],
      },
      request: { url: 'http://localhost:3001/api/series/42?t=1' },
    }
    const result = beforeSend(event)
    expect(result.message).toBe('Failed to transcode ~/Movies/*.mkv')
    expect(result.exception.values[0].value).toBe('Cannot read ~/*.mkv')
    expect(result.exception.values[0].stacktrace.frames[0].filename)
      .toBe('~/code/caramba/web/src/App.jsx')
    expect(result.request.url).toBe('http://localhost:3001/api/series/:id')
  })

  it('returns the same event object (mutates in place is fine)', () => {
    const event = { message: 'ok' }
    expect(beforeSend(event)).toBe(event)
  })

  it('tolerates missing optional fields', () => {
    expect(beforeSend({})).toEqual({})
  })

  it('clears event.request.query_string', () => {
    const event = {
      request: { url: '/api/x?t=1', query_string: 'q=sopranos&page=2' },
    }
    beforeSend(event)
    expect(event.request.url).toBe('/api/x')
    expect(event.request.query_string).toBe('')
  })

  it('scrubs frame abs_path alongside filename', () => {
    const event = {
      exception: { values: [{
        stacktrace: { frames: [
          { filename: 'app:///index.js', abs_path: '/Users/vladyslav/app.js' },
        ]},
      }]},
    }
    beforeSend(event)
    expect(event.exception.values[0].stacktrace.frames[0].abs_path)
      .toBe('~/app.js')
  })

  it('deletes event.user.username', () => {
    const event = { user: { username: 'vladyslav', id: '1' } }
    beforeSend(event)
    expect(event.user.username).toBeUndefined()
    expect(event.user.id).toBe('1')
  })
})

describe('beforeBreadcrumb', () => {
  it('scrubs message and data.url and data.to', () => {
    const crumb = {
      message: 'Navigation to /series/42',
      data: {
        url: 'http://localhost:3001/api/series/42?t=1',
        to: '/series/42/episode/7',
      },
    }
    const result = beforeBreadcrumb(crumb)
    expect(result.message).toBe('Navigation to /series/:id')
    expect(result.data.url).toBe('http://localhost:3001/api/series/:id')
    expect(result.data.to).toBe('/series/:id/episode/:id')
  })

  it('scrubs data.from on navigation breadcrumbs', () => {
    const crumb = { data: { from: '/series/42', to: '/series/43' } }
    beforeBreadcrumb(crumb)
    expect(crumb.data.from).toBe('/series/:id')
    expect(crumb.data.to).toBe('/series/:id')
  })

  it('tolerates missing data', () => {
    expect(beforeBreadcrumb({ message: 'x' })).toEqual({ message: 'x' })
  })
})
