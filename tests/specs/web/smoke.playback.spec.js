const { test, expect } = require('../../fixtures/base')
const { assertPlayback } = require('../../fixtures/asserts')

test('@smoke first movie plays for 30s with checkpoints + seek', async ({ page, library }) => {
  const movie = await library.firstMovie()
  await page.goto(`/movies/${movie.slug}`)

  const playButton = page.getByRole('button', { name: /play|resume/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()

  const result = await assertPlayback(page)
  expect(result.checkpoints.length).toBe(3)
  expect(result.seek.after).toBeGreaterThan(result.seek.to)
})
