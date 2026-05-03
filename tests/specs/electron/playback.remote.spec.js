// Hybrid mode + local_playback: false — playback should stream from the
// Rails server's HLS pipeline instead of the local Electron transcoder.
// This pins whether the "Local Playback" Settings toggle still works.
const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { probeFirstMovie } = require('../../fixtures/library')
const { assertPlayback } = require('../../fixtures/asserts')
const { writeBundleFile, formatMainLog, attachConsoleCapture, captureVideoFinalState } = require('../../fixtures/diagnostics')
const { startTail, captureSince } = require('../../fixtures/serverLog')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid({ localPlayback: false })
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

test('@playback hybrid + local_playback=false streams from server', async ({ electron }) => {
  const movie = await probeFirstMovie('http://localhost:3001')
  const { window, mainLog } = electron
  await window.waitForLoadState('domcontentloaded')
  await window.evaluate((h) => { window.location.hash = h }, `/movies/${movie.slug}`)
  const playButton = window.getByRole('button', { name: /play|resume/i }).first()
  await expect(playButton).toBeVisible({ timeout: 15_000 })
  await playButton.click()
  // Same readyState>=2 + checkpoint + seek probe as the local-playback test.
  const result = await assertPlayback(window)
  expect(result.checkpoints.length).toBe(3)

  // Pin the routing: when local_playback=false, no local desktop ffmpeg
  // session should have been started — all transcoding lives on Rails.
  const startedLocal = mainLog.some(l => /Transcoder: started /.test(l.text))
  expect(startedLocal).toBe(false)
})
