const { expect } = require('@playwright/test')

async function assertPlayback(page, {
  checkpoints = [5_000, 15_000, 25_000],
  // 25% tolerance: real playback loses fractions of a second to buffer
  // hiccups, especially on the first checkpoint while hls.js stabilises.
  // Tighter tolerance flags those as stalls — false positives. A genuine
  // stall is multi-second and still trips this threshold easily.
  toleranceFraction = 0.25,
  seekProbe = true,
} = {}) {
  // 60s ceiling: covers slow-but-valid full_transcode startup (4K HEVC etc.).
  // If readyState>=2 isn't reached in 60s, that's a real signal worth surfacing.
  await page.waitForFunction(() => {
    const v = document.querySelector('video')
    return v && v.readyState >= 2
  }, null, { timeout: 60_000 })

  const t0 = await page.evaluate(() => document.querySelector('video').currentTime)
  const startedAt = Date.now()
  const results = []

  for (const ms of checkpoints) {
    const elapsed = Date.now() - startedAt
    if (elapsed < ms) await page.waitForTimeout(ms - elapsed)

    const sample = await page.evaluate(() => {
      const v = document.querySelector('video')
      return {
        currentTime: v.currentTime,
        paused: v.paused,
        readyState: v.readyState,
        error: v.error?.code ?? null,
        hlsErrors: window.__caramba_hls_errors__ || [],
      }
    })

    const expectedMs = ms * (1 - toleranceFraction)
    const expectedSec = expectedMs / 1000
    const advanced = sample.currentTime - t0
    results.push({ checkpointMs: ms, advancedSec: advanced, expectedSec, sample })
    expect(advanced, `Stalled at checkpoint ${ms}ms (advanced ${advanced.toFixed(2)}s, expected ≥ ${expectedSec.toFixed(2)}s)`).toBeGreaterThanOrEqual(expectedSec)
    const fatal = sample.hlsErrors.filter(e => e.fatal)
    expect(fatal, `Fatal hls.js errors at checkpoint ${ms}ms: ${JSON.stringify(fatal)}`).toEqual([])
  }

  if (!seekProbe) return { t0, checkpoints: results }

  const seekTo = await page.evaluate(() => {
    const v = document.querySelector('video')
    return Math.min(v.currentTime + 60, v.duration > 0 ? v.duration / 2 : v.currentTime + 60)
  })
  await page.evaluate((t) => { document.querySelector('video').currentTime = t }, seekTo)
  await page.waitForTimeout(5_000)
  const afterSeek = await page.evaluate(() => document.querySelector('video').currentTime)
  expect(afterSeek, `Seek to ${seekTo} failed; player at ${afterSeek}`).toBeGreaterThan(seekTo)

  return { t0, checkpoints: results, seek: { to: seekTo, after: afterSeek } }
}

module.exports = { assertPlayback }
