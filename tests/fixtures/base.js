const { test: baseTest } = require('@playwright/test')
const { ensureRails } = require('./server')
const { probeFirstShow, probeFirstMovie, probeFirstEpisode } = require('./library')
const { attachConsoleCapture, captureVideoFinalState, writeBundleFile } = require('./diagnostics')
const { startTail, captureSince } = require('./serverLog')

const test = baseTest.extend({
  apiBase: async ({}, use) => {
    const { apiBase } = await ensureRails()
    await use(apiBase)
  },
  library: async ({ apiBase }, use) => {
    await use({
      firstShow: () => probeFirstShow(apiBase),
      firstMovie: () => probeFirstMovie(apiBase),
      firstEpisode: () => probeFirstEpisode(apiBase),
    })
  },
  page: async ({ page }, use, testInfo) => {
    await page.addInitScript(() => {
      try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
    })
    const consoleCap = attachConsoleCapture(page)
    const tail = startTail()
    await use(page)
    writeBundleFile(testInfo, 'console.browser.log',
      consoleCap.snapshot().map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}${l.url ? ` (${l.url}:${l.lineNumber ?? '?'})` : ''}`).join('\n'))
    writeBundleFile(testInfo, 'ffmpeg.server.log', captureSince(tail))
    let videoState = null
    try { videoState = await captureVideoFinalState(page) } catch {}
    const stub = {
      test: testInfo.title,
      project: testInfo.project.name,
      status: testInfo.status,
      duration: testInfo.duration,
      target: testInfo.annotations.find(a => a.type === 'target')?.description || null,
      video: videoState,
      console: consoleCap.counts(),
    }
    writeBundleFile(testInfo, 'summary.partial.json', stub)
  },
})

module.exports = { test, expect: baseTest.expect }
