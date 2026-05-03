// Iterate every movie in the library and verify playback. Diagnostic test:
// for each failure, dump the strategy chosen + ffmpeg progress.
const { test: baseTest, expect } = require('@playwright/test')
const { launchHybrid } = require('../../electron/launch')
const { assertPlayback } = require('../../fixtures/asserts')
const { writeBundleFile, formatMainLog, attachConsoleCapture } = require('../../fixtures/diagnostics')

const test = baseTest.extend({
  electron: async ({}, use, testInfo) => {
    const ctx = await launchHybrid({ localPlayback: true })
    const consoleCap = attachConsoleCapture(ctx.window)
    await use({ ...ctx, consoleCap })
    writeBundleFile(testInfo, 'console.electron-main.log', formatMainLog(ctx.mainLog))
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n'))
    await ctx.close()
  },
})

test('@playback every movie in the library plays', async ({ electron }, testInfo) => {
  const { window, mainLog, consoleCap } = electron
  const apiBase = 'http://localhost:3001'

  const moviesRes = await fetch(`${apiBase}/api/movies`)
  const movies = await moviesRes.json()
  expect(movies.length).toBeGreaterThan(0)

  await window.waitForLoadState('domcontentloaded')

  const report = []

  for (const movie of movies) {
    const heading = `\n=== ${movie.slug} (${movie.title}) ===`
    console.log(heading)
    const beforeMain = mainLog.length
    const beforeBrowser = consoleCap.snapshot().length

    // Reset progress in Rails so the test always starts at 0 and we get a
    // clean strategy decision (some 10-bit Main 10 sources stall mid-file
    // when resumed near a non-keyframe boundary).
    await fetch(`${apiBase}/api/playback/report_progress`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ movie_id: movie.id, time: 0, duration: 1 }),
    }).catch(() => {})

    await window.evaluate((h) => { window.location.hash = h }, `/movies/${movie.slug}`)
    const playButton = window.getByRole('button', { name: /play|resume/i }).first()
    await expect(playButton).toBeVisible({ timeout: 15_000 })
    await playButton.click()

    let result, error
    try {
      // No seek probe — we're checking the simpler "does it play smoothly" question.
      result = await assertPlayback(window, { seekProbe: false })
    } catch (e) {
      error = e.message
    }

    const newMainLines = mainLog.slice(beforeMain).map(l => l.text).filter(t => /Transcoder:|stream:\/\//i.test(t))
    const newBrowserLines = consoleCap.snapshot().slice(beforeBrowser).map(l => l.text).filter(t => /\[Player\]|hls\.js|stalled|fatal/i.test(t))
    const startLine = mainLog.slice(beforeMain).map(l => l.text).find(t => /Transcoder: started/.test(t)) || '(none)'

    report.push({
      slug: movie.slug,
      title: movie.title,
      filePath: movie.file_path,
      passed: !error,
      error: error || null,
      strategyLine: startLine,
      mainLines: newMainLines.slice(0, 20),
      browserLines: newBrowserLines.slice(0, 20),
    })

    // Close the player between movies. Try Escape; if that doesn't close it
    // we'll just navigate to a different URL on the next loop iteration.
    await window.keyboard.press('Escape').catch(() => {})
    await window.waitForTimeout(500)
  }

  writeBundleFile(testInfo, 'all-movies.report.json', report)

  // Summary
  const failed = report.filter(r => !r.passed)
  const summary = report.map(r =>
    `${r.passed ? '✓' : '✗'} ${r.slug}\n    ${r.strategyLine}\n    ${r.error || ''}`
  ).join('\n')
  console.log('\n--- summary ---\n' + summary)

  expect(failed, `${failed.length}/${movies.length} movies failed playback:\n${failed.map(r => `${r.slug}: ${r.error}`).join('\n')}`).toEqual([])
})
