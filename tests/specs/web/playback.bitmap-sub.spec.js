const { test, expect } = require('../../fixtures/base')
const { resolveTarget } = require('../../fixtures/target')
const { assertPlayback } = require('../../fixtures/asserts')

// Regression for the runaway-request bug: a 4K source whose only subtitle
// tracks are bitmap (PGS/VOBSUB) used to trip select_subtitle_track into
// auto-burning the bitmap, which forces full_transcode → encode <1× realtime
// → segment 404 storm → unbounded hls.js startLoad() loop. After Task 1+2 in
// plan.md, the run must:
//   - select no subtitle (strategy != full_transcode, isBitmapSubtitle false)
//   - keep playback ready within budget with no fatal hls.js errors
//   - issue at most a small handful of segment 404s — never a sustained storm
//
// The target source is library-dependent; gate behind CARAMBA_BITMAP_TARGET
// so devs without a matching fixture skip rather than fail spuriously.

const SEGMENT_404_BUDGET = 10

test('@playback bitmap-only-sub source plays without 404 storm', async ({ page, library, apiBase }, testInfo) => {
  const targetEnv = process.env.CARAMBA_BITMAP_TARGET
  test.skip(!targetEnv, 'set CARAMBA_BITMAP_TARGET=movie:<slug> or show:<slug> to exercise this regression')

  const target = resolveTarget(targetEnv)
  testInfo.annotations.push({ type: 'target', description: JSON.stringify(target) })

  let route
  if (target.kind === 'movie') route = `/movies/${target.slug}`
  else if (target.kind === 'show') route = `/shows/${target.slug}`
  else if (target.kind === 'slug') route = `/movies/${target.slug}`
  else throw new Error(`Unsupported target for this spec: ${targetEnv}`)

  // Capture the /api/playback/start response so we can assert strategy +
  // subtitle selection without scraping the UI.
  const startPromise = page.waitForResponse(
    (resp) => resp.url().includes('/api/playback/start') && resp.request().method() === 'POST',
    { timeout: 30_000 }
  )

  // Tally segment / playlist 404s. The bug's signature is dozens per second
  // on the same handful of URLs.
  const segment404s = []
  page.on('response', (resp) => {
    if (resp.status() !== 404) return
    const url = resp.url()
    if (/\/api\/playback\/hls\/[^/]+\/(playlist\.m3u8|segment_.+\.m4s)/.test(url)) {
      segment404s.push({ url, ts: Date.now() })
    }
  })

  await page.goto(route)
  const cta = page.locator('.btn-play-cta, button:has-text("Resume"), button:has-text("Play")').first()
  await expect(cta).toBeVisible({ timeout: 15_000 })
  await cta.click()

  const startResp = await startPromise
  const startBody = await startResp.json()
  testInfo.annotations.push({ type: 'start-response', description: JSON.stringify({
    strategy: startBody.strategy,
    isBitmapSubtitle: startBody.isBitmapSubtitle,
    activeSubtitleIndex: startBody.activeSubtitleIndex,
    subtitleStreamCount: (startBody.subtitleStreams || []).length,
  }) })

  const subStreams = startBody.subtitleStreams || []
  const hasText = subStreams.some(s => s.isText)
  const hasBitmap = subStreams.some(s => !s.isText)
  test.skip(!hasBitmap || hasText,
    `target ${targetEnv} is not bitmap-only (hasBitmap=${hasBitmap}, hasText=${hasText}) — pick a source whose only subs are PGS/VOBSUB`)

  // Core regression assertions — Task 2: no auto-pick of bitmap when no pref.
  expect(startBody.isBitmapSubtitle, 'bitmap sub should not be auto-burned').toBe(false)
  expect(startBody.activeSubtitleIndex, 'no subtitle should be active without a saved pref').toBeNull()
  expect(startBody.strategy, 'strategy should not escalate to full_transcode for bitmap-only without pref')
    .not.toBe('full_transcode')

  // Existing checkpoints helper covers: readyState>=2 within 60s, advancement
  // within tolerance at 5/15/25s, and no fatal hls.js errors.
  const result = await assertPlayback(page, { seekProbe: false })
  expect(result.checkpoints.length).toBe(3)

  // Task 1: circuit breaker prevents the storm. Even on a slow encoder a
  // healthy session should not cross this threshold; the bug emitted dozens.
  expect(segment404s.length,
    `Segment/playlist 404 storm: ${segment404s.length} 404s — fatal-error retry budget likely failing.\n` +
    segment404s.slice(0, 5).map(e => `  ${e.url}`).join('\n')
  ).toBeLessThan(SEGMENT_404_BUDGET)
})
