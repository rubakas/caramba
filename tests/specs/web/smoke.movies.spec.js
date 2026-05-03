const { test, expect } = require('../../fixtures/base')

test('@smoke movies page renders and shows the first movie', async ({ page, library }) => {
  const first = await library.firstMovie()
  await page.goto('/movies')
  // PosterCard renders div[role="button"] with aria-label={item.title} for movies
  // (item.name for shows). See ui/components/PosterCard.jsx.
  const card = page.getByRole('button', { name: first.title }).first()
  await expect(card).toBeVisible({ timeout: 15_000 })
})
