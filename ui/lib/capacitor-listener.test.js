import { describe, test, expect, vi } from 'vitest'
import { subscribeCapacitorListener } from './capacitor-listener'

describe('subscribeCapacitorListener', () => {
  test('handles Promise-returning addListener (Capacitor 6+)', async () => {
    const remove = vi.fn()
    const plugin = {
      addListener: vi.fn().mockResolvedValue({ remove }),
    }
    const unsub = subscribeCapacitorListener(plugin, 'foo', () => {})
    expect(plugin.addListener).toHaveBeenCalledWith('foo', expect.any(Function))
    // Wait for the resolved handle to be stashed.
    await Promise.resolve()
    unsub()
    expect(remove).toHaveBeenCalledTimes(1)
  })

  test('handles sync-returning addListener (older Capacitor / CarambaPlayer)', () => {
    const remove = vi.fn()
    const plugin = {
      addListener: vi.fn().mockReturnValue({ remove }),
    }
    // Regression: this used to throw "X?.then is not a function" because
    // VideoPlayer's cleanup called `.then` on a sync handle.
    expect(() => {
      const unsub = subscribeCapacitorListener(plugin, 'dismissed', () => {})
      unsub()
    }).not.toThrow()
    expect(remove).toHaveBeenCalledTimes(1)
  })

  test('removes on Promise arrival when unsub fires first', async () => {
    const remove = vi.fn()
    let resolveHandle
    const plugin = {
      addListener: vi.fn().mockReturnValue(
        new Promise(resolve => { resolveHandle = resolve })
      ),
    }
    const unsub = subscribeCapacitorListener(plugin, 'foo', () => {})
    unsub()                           // unmount before Promise resolves
    resolveHandle({ remove })         // handle arrives late
    await Promise.resolve()
    expect(remove).toHaveBeenCalledTimes(1)
  })

  test('no-op when plugin is missing', () => {
    expect(() => subscribeCapacitorListener(undefined, 'foo', () => {})()).not.toThrow()
    expect(() => subscribeCapacitorListener({}, 'foo', () => {})()).not.toThrow()
  })

  test('swallows Promise rejection from addListener', async () => {
    const plugin = {
      addListener: vi.fn().mockRejectedValue(new Error('boom')),
    }
    const unsub = subscribeCapacitorListener(plugin, 'foo', () => {})
    await Promise.resolve()
    expect(() => unsub()).not.toThrow()
  })
})
