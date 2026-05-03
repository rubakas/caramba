const { test, expect } = require('../../fixtures/base')
const { resolveTarget } = require('../../fixtures/target')
const { probeEpisode } = require('../../fixtures/library')
const { assertPlayback } = require('../../fixtures/asserts')

test('@playback parameterized playback (web)', async ({ page, library, apiBase }, testInfo) => {
  const target = resolveTarget(process.env.CARAMBA_TEST_TARGET)
  testInfo.annotations.push({ type: 'target', description: JSON.stringify(target) })

  if (target.kind === 'file') {
    test.skip(true, 'file: targets are exercised via the electron project')
    return
  }

  // Resolve target to a route. Show/episode targets navigate to the show page
  // and click the main Play/Resume CTA — works for any episode without
  // wrestling with virtualised lists or per-episode pointer interception.
  let route
  if (target.kind === 'auto' || target.kind === 'movie') {
    const slug = target.kind === 'auto' ? (await library.firstMovie()).slug : target.slug
    route = `/movies/${slug}`
  } else if (target.kind === 'slug') {
    // Bare slug — try movie first, fall back to show
    route = `/movies/${target.slug}`
  } else if (target.kind === 'show') {
    route = `/shows/${target.slug}`
  } else if (target.kind === 'episode') {
    const ep = await probeEpisode(apiBase, target.id)
    route = `/shows/${ep.showSlug}`
  }

  await page.goto(route)
  // The CTA is class .btn-play-cta with text "Play" or "Resume" (or "Loading..." while launching).
  // Show page renders a single CTA; movie page may have several /play/i buttons — first matches Resume/Play primary.
  const cta = page.locator('.btn-play-cta, button:has-text("Resume"), button:has-text("Play")').first()
  await expect(cta).toBeVisible({ timeout: 15_000 })
  await cta.click()
  const result = await assertPlayback(page, { seekProbe: true })
  expect(result.checkpoints.length).toBe(3)
})
