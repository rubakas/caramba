import { describe, test, expect, beforeEach, vi } from 'vitest'
import { createHttpAdapter } from './http'

describe('http adapter test-mode header', () => {
  beforeEach(() => {
    globalThis.localStorage = {
      _store: {},
      getItem(k) { return this._store[k] || null },
      setItem(k, v) { this._store[k] = v },
      removeItem(k) { delete this._store[k] },
    }
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      headers: { get: () => 'application/json' },
      json: async () => ({ ok: true }),
    })
  })

  test('omits X-Test-Run header by default', async () => {
    const adapter = createHttpAdapter('http://localhost:3001')
    await adapter.listShows()
    const init = globalThis.fetch.mock.calls[0][1] || {}
    const headers = init.headers || {}
    expect(headers['X-Test-Run']).toBeUndefined()
  })

  test('sends X-Test-Run: 1 when localStorage flag set', async () => {
    globalThis.localStorage.setItem('__caramba_test_run__', '1')
    const adapter = createHttpAdapter('http://localhost:3001')
    await adapter.listShows()
    const init = globalThis.fetch.mock.calls[0][1] || {}
    const headers = init.headers || {}
    expect(headers['X-Test-Run']).toBe('1')
  })
})

describe('http adapter shape', () => {
  // Regression: NativeVideoPlayer used `api.baseUrl?.()` (wrong name AND
  // treated it as a function), so the Android TV CarambaPlayer Activity
  // received `apiBase: ''` and never started playback. Lock the name
  // and shape so any future rename trips the test instead of the user.
  test('exposes server URL as the string property `apiBase`', () => {
    const adapter = createHttpAdapter('http://10.0.0.200:3001/')
    expect(adapter.apiBase).toBe('http://10.0.0.200:3001')
    expect(typeof adapter.apiBase).toBe('string')
  })
})
