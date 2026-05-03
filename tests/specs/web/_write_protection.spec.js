const { test, expect } = require('../../fixtures/base')

test('@smoke localStorage carries the test-run flag inside the app', async ({ page }) => {
  await page.goto('/')
  const flag = await page.evaluate(() => localStorage.getItem('__caramba_test_run__'))
  expect(flag).toBe('1')
})

test('@smoke /api/movies request carries X-Test-Run header from the app', async ({ page }) => {
  const headers = []
  page.on('request', (req) => {
    if (req.url().includes('/api/')) headers.push(req.headers())
  })
  await page.goto('/movies')
  await page.waitForLoadState('networkidle')
  expect(headers.length).toBeGreaterThan(0)
  expect(headers.some(h => h['x-test-run'] === '1')).toBe(true)
})

test('@smoke playback does not mutate Movie#progress_seconds', async ({ page, library, apiBase }) => {
  const movie = await library.firstMovie()

  const beforeRes = await fetch(`${apiBase}/api/movies/${movie.slug}`)
  const before = await beforeRes.json()
  const beforeProgress = before.progress_seconds ?? null

  await page.goto(`/movies/${movie.slug}`)
  const playButton = page.getByRole('button', { name: /play|resume/i }).first()
  await playButton.click()
  await page.waitForFunction(() => {
    const v = document.querySelector('video')
    return v && v.currentTime > 5
  }, null, { timeout: 90_000 })
  // Long enough for at least one report_progress fire (~10s interval in player)
  await page.waitForTimeout(15_000)

  const afterRes = await fetch(`${apiBase}/api/movies/${movie.slug}`)
  const after = await afterRes.json()
  const afterProgress = after.progress_seconds ?? null

  expect(afterProgress).toBe(beforeProgress)
})
