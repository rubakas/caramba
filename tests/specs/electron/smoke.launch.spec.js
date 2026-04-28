const { test: baseTest } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')

const test = baseTest.extend({
  electron: async ({}, use) => {
    const ctx = await launchHybrid()
    await use(ctx)
    await ctx.close()
  },
})

test('@smoke electron launches in hybrid mode and renders shows page', async ({ electron }) => {
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  // Wait for at least one show poster to appear (proves hybrid mode is live).
  // PosterCard renders div[role="button"] — the link href is unused. Match by role.
  await window.waitForSelector('[role="button"][aria-label]', { timeout: 30_000 })
})
