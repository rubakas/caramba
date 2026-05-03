const { test, expect } = require('../../fixtures/base')

test('@smoke shows page renders and shows the first show', async ({ page, library }) => {
  const first = await library.firstShow()
  await page.goto('/')
  // PosterCard renders as a div[role="button"] with aria-label set to the show name.
  // Wait for the shows grid to populate by checking for the card.
  const card = page.getByRole('button', { name: first.name }).first()
  await expect(card).toBeVisible({ timeout: 15_000 })
})
