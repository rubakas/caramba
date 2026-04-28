const fs = require('fs')
const path = require('path')

function attachConsoleCapture(page) {
  const lines = []
  page.on('console', (msg) => {
    const loc = msg.location()
    lines.push({
      ts: new Date().toISOString(),
      type: msg.type(),
      text: msg.text(),
      url: loc.url || null,
      lineNumber: loc.lineNumber ?? null,
    })
  })
  page.on('pageerror', (err) => {
    lines.push({
      ts: new Date().toISOString(),
      type: 'pageerror',
      text: `${err.name}: ${err.message}\n${err.stack || ''}`,
    })
  })
  return {
    snapshot() { return lines.slice() },
    counts() {
      return {
        error: lines.filter(l => l.type === 'error' || l.type === 'pageerror').length,
        warning: lines.filter(l => l.type === 'warning' || l.type === 'warn').length,
        total: lines.length,
      }
    },
  }
}

async function captureVideoFinalState(page) {
  return page.evaluate(() => {
    const v = document.querySelector('video')
    if (!v) return null
    return {
      currentTime: v.currentTime,
      duration: Number.isFinite(v.duration) ? v.duration : null,
      paused: v.paused,
      readyState: v.readyState,
      networkState: v.networkState,
      errorCode: v.error?.code ?? null,
      hlsErrors: window.__caramba_hls_errors__ || [],
      hlsStrategy: window.__caramba_hls_strategy__ || null,
    }
  })
}

function writeBundleFile(testInfo, name, contents) {
  const dir = testInfo.outputDir
  fs.mkdirSync(dir, { recursive: true })
  const p = path.join(dir, name)
  fs.writeFileSync(p, typeof contents === 'string' ? contents : JSON.stringify(contents, null, 2))
  return p
}

function formatMainLog(lines) {
  return lines.map(l => `[${l.ts}] ${l.type.toUpperCase()} ${l.text}`).join('\n')
}

module.exports = {
  attachConsoleCapture,
  captureVideoFinalState,
  writeBundleFile,
  formatMainLog,
}
