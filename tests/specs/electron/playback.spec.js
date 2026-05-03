const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { resolveTarget } = require('../../fixtures/target')
const { probeFirstMovie, probeEpisode } = require('../../fixtures/library')
const { assertPlayback } = require('../../fixtures/asserts')
const { writeBundleFile, formatMainLog, attachConsoleCapture, captureVideoFinalState } = require('../../fixtures/diagnostics')
const { startTail, captureSince } = require('../../fixtures/serverLog')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid()
    const consoleCap = attachConsoleCapture(ctx.window)
    const tail = startTail()
    await use(ctx)
    writeBundleFile(testInfo, 'console.electron-main.log', formatMainLog(ctx.mainLog))
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n'))
    writeBundleFile(testInfo, 'ffmpeg.server.log', captureSince(tail))
    let videoState = null
    try { videoState = await captureVideoFinalState(ctx.window) } catch {}
    writeBundleFile(testInfo, 'summary.partial.json', {
      test: testInfo.title,
      project: testInfo.project.name,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
    })
    await ctx.close()
  },
})

test('@playback parameterized playback (electron)', async ({ electron }, testInfo) => {
  const target = resolveTarget(process.env.CARAMBA_TEST_TARGET)
  testInfo.annotations.push({ type: 'target', description: JSON.stringify(target) })
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  const apiBase = 'http://localhost:3001'

  let route
  if (target.kind === 'auto' || target.kind === 'movie') {
    const slug = target.kind === 'auto' ? (await probeFirstMovie(apiBase)).slug : target.slug
    route = `/movies/${slug}`
  } else if (target.kind === 'slug') {
    route = `/movies/${target.slug}`
  } else if (target.kind === 'show') {
    route = `/shows/${target.slug}`
  } else if (target.kind === 'episode') {
    const ep = await probeEpisode(apiBase, target.id)
    route = `/shows/${ep.showSlug}`
  } else if (target.kind === 'file') {
    const res = await fetch(`${apiBase}/api/movies`)
    const movies = await res.json()
    const m = movies.find(mm => mm.file_path === target.filePath || mm.filePath === target.filePath)
    if (!m) {
      writeBundleFile(testInfo, 'summary.partial.json', { phase: 'resolveTarget', error: `No movie with filePath ${target.filePath}`, target })
      throw new Error(`No movie in library with filePath ${target.filePath}`)
    }
    route = `/movies/${m.slug}`
  }

  await window.evaluate((h) => { window.location.hash = h }, route)
  const cta = window.locator('.btn-play-cta, button:has-text("Resume"), button:has-text("Play")').first()
  await expect(cta).toBeVisible({ timeout: 15_000 })
  await cta.click()
  const result = await assertPlayback(window, { seekProbe: true })
  expect(result.checkpoints.length).toBe(3)
})
