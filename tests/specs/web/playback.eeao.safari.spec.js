// Regression: HEVC + AC3 source on Safari (webkit native HLS).
// Tagged @safari so the `safari` Playwright project (webkit engine) runs
// it; the default `web` project (Desktop Chrome) skips it via the grep.
//
// EEAAO ("Everything Everywhere All at Once") is the specific 1080p
// HEVC 10-bit + 3× AC3 MKV that exposed the Safari playback failure
// chain we worked through: subtitle indexing, mpegts pre-roll, MSE vs
// native-HLS profile probing, Decision module's asymmetric HEVC
// profile constraint. Keep this test pinned to this exact source so the
// fix combination doesn't quietly regress.
const { test, expect } = require('../../fixtures/base')
const { assertPlayback } = require('../../fixtures/asserts')

test('@safari plays Everything Everywhere All at Once (HEVC+AC3, native HLS)', async ({ page, apiBase }) => {
  const slug = 'everything-everywhere-all-at-once-2022'
  const probe = await fetch(`${apiBase}/api/movies/${slug}`)
  test.skip(!probe.ok, `movie '${slug}' not in library`)

  await page.goto(`/movies/${slug}`)

  const playButton = page.getByRole('button', { name: /play|resume/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()

  // assertPlayback waits for readyState>=2 (HAVE_CURRENT_DATA) then
  // checkpoints currentTime at 5/15/25s. The Safari failure mode for
  // this source was "one frame, then stall" — currentTime locked at 0
  // — so the 5s checkpoint alone is sufficient to catch it.
  const result = await assertPlayback(page, { checkpoints: [5_000], seekProbe: false })
  expect(result.checkpoints[0].sample.error).toBeNull()
})
