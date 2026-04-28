const fs = require('fs')
const os = require('os')
const path = require('path')
const { _electron: electron } = require('@playwright/test')

const DESKTOP_DIR = path.resolve(__dirname, '..', '..', 'desktop')

async function launchHybrid({ apiBase = 'http://localhost:3001', viteDevUrl = 'http://localhost:5173' } = {}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'caramba-test-'))
  const storageDir = path.join(tempDir, 'storage')
  fs.mkdirSync(storageDir, { recursive: true })
  fs.writeFileSync(
    path.join(storageDir, 'api_config.json'),
    JSON.stringify({ enabled: true, server_url: apiBase, local_playback: true }, null, 2),
  )

  const mainLog = []
  const app = await electron.launch({
    args: ['./electron/main.js'],
    cwd: DESKTOP_DIR,
    env: {
      ...process.env,
      CARAMBA_STORAGE_PATH: storageDir,
      VITE_DEV_URL: viteDevUrl,
      ELECTRON_DISABLE_SECURITY_WARNINGS: '1',
    },
    timeout: 30_000,
  })
  app.on('console', (msg) => {
    mainLog.push({ ts: new Date().toISOString(), type: msg.type(), text: msg.text() })
  })
  app.process().stdout?.on('data', (d) => mainLog.push({ ts: new Date().toISOString(), type: 'stdout', text: d.toString() }))
  app.process().stderr?.on('data', (d) => mainLog.push({ ts: new Date().toISOString(), type: 'stderr', text: d.toString() }))

  // Wait for the app window (not the DevTools detach window).
  // main.js calls openDevTools({ mode: 'detach' }) in dev, which creates a second
  // BrowserWindow. firstWindow() may return the DevTools window instead of the app.
  // We identify the app window by excluding the DevTools window (URL starts with devtools://).
  async function getAppWindow(timeoutMs = 30_000) {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      const wins = app.windows()
      for (const w of wins) {
        const url = w.url()
        // Skip the detached DevTools window
        if (url.startsWith('devtools://')) continue
        // Any non-devtools window is the app window (may be http://, file://, about:blank, chrome-error://)
        return w
      }
      // Wait for the next window event then re-check
      await Promise.race([
        app.waitForEvent('window', { timeout: Math.min(5000, deadline - Date.now()) }).catch(() => null),
        new Promise(r => setTimeout(r, 500)),
      ])
    }
    throw new Error(`App window (non-devtools) not found within ${timeoutMs}ms`)
  }

  const window = await getAppWindow(30_000)
  await window.addInitScript(() => {
    try { localStorage.setItem('__caramba_test_run__', '1') } catch {}
  })
  return {
    app,
    window,
    tempDir,
    mainLog,
    async close() {
      try { await app.close() } catch {}
      try { fs.rmSync(tempDir, { recursive: true, force: true }) } catch {}
    },
  }
}

module.exports = { launchHybrid }
