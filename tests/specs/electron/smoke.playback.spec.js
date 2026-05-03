const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { probeFirstMovie } = require('../../fixtures/library')
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
      mainLogLines: ctx.mainLog.length,
    })
    await ctx.close()
  },
})

async function navigateHash(window, hashRoute) {
  // Electron renderer uses HashRouter — change location.hash rather than goto().
  await window.evaluate((h) => { window.location.hash = h }, hashRoute)
}

test('@smoke electron plays first movie for 30s + seek probe', async ({ electron }) => {
  const movie = await probeFirstMovie('http://localhost:3001')
  const { window } = electron
  await window.waitForLoadState('domcontentloaded')
  await navigateHash(window, `/movies/${movie.slug}`)
  const playButton = window.getByRole('button', { name: /play|resume/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()
  const result = await assertPlayback(window)
  expect(result.checkpoints.length).toBe(3)
  expect(result.seek.after).toBeGreaterThan(result.seek.to)
})
