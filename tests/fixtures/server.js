// Probe-and-fallback for the Rails dev server on :3001 and Vite web on :3000.
// If a server answers, reuse it (most common during dev). If not,
// spawn it from the correct directory and wait for it to become healthy.
const { spawn } = require('child_process')
const path = require('path')

const RAILS_PORT = 3001
const HEALTH_URL = `http://localhost:${RAILS_PORT}/api/health`
const VITE_WEB_PORT = 3000
const VITE_DESKTOP_PORT = 5173

async function probeHealth(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(HEALTH_URL, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

async function waitForHealth(maxMs = 30_000) {
  const start = Date.now()
  while (Date.now() - start < maxMs) {
    if (await probeHealth()) return true
    await new Promise(r => setTimeout(r, 500))
  }
  return false
}

let spawnedProc = null

async function ensureRails() {
  if (await probeHealth()) return { spawned: false, apiBase: `http://localhost:${RAILS_PORT}` }

  const serverDir = path.resolve(__dirname, '..', '..', 'server')
  const verbose = process.env.CARAMBA_TEST_VERBOSE === '1'
  spawnedProc = spawn('bin/rails', ['server', '-p', String(RAILS_PORT), '-b', '0.0.0.0'], {
    cwd: serverDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, RAILS_ENV: 'development' },
    detached: false,
  })
  // Always surface stderr so a failed boot is debuggable; gate stdout on env to avoid noise.
  spawnedProc.stdout.on('data', (d) => { if (verbose) process.stderr.write(`[rails] ${d}`) })
  spawnedProc.stderr.on('data', (d) => process.stderr.write(`[rails-err] ${d}`))

  const ok = await waitForHealth()
  if (!ok) {
    try { spawnedProc.kill('SIGTERM') } catch {}
    spawnedProc = null
    throw new Error('Rails did not become healthy on :3001 within 30s')
  }
  return { spawned: true, apiBase: `http://localhost:${RAILS_PORT}` }
}

async function probeViteWeb(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(`http://localhost:${VITE_WEB_PORT}/`, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

let viteProc = null
async function ensureViteWeb() {
  if (await probeViteWeb()) return { spawned: false }
  const webDir = path.resolve(__dirname, '..', '..', 'web')
  const verbose = process.env.CARAMBA_TEST_VERBOSE === '1'
  viteProc = spawn('pnpm', ['exec', 'vite', '--port', String(VITE_WEB_PORT), '--host'], {
    cwd: webDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
    detached: false,
  })
  viteProc.stdout.on('data', (d) => { if (verbose) process.stderr.write(`[vite] ${d}`) })
  viteProc.stderr.on('data', (d) => process.stderr.write(`[vite-err] ${d}`))

  const start = Date.now()
  while (Date.now() - start < 30_000) {
    if (await probeViteWeb()) return { spawned: true }
    await new Promise(r => setTimeout(r, 500))
  }
  try { viteProc.kill('SIGTERM') } catch {}
  viteProc = null
  throw new Error('Vite web did not become healthy on :3000 within 30s')
}

async function probeViteDesktop(timeoutMs = 1000) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetch(`http://localhost:${VITE_DESKTOP_PORT}/`, { signal: ctrl.signal })
    return res.ok
  } catch {
    return false
  } finally {
    clearTimeout(t)
  }
}

let viteDesktopProc = null
async function ensureViteDesktop() {
  if (await probeViteDesktop()) return { spawned: false }
  const desktopDir = path.resolve(__dirname, '..', '..', 'desktop')
  const verbose = process.env.CARAMBA_TEST_VERBOSE === '1'
  viteDesktopProc = spawn('pnpm', ['exec', 'vite', '--port', String(VITE_DESKTOP_PORT)], {
    cwd: desktopDir,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
    detached: false,
  })
  viteDesktopProc.stdout.on('data', (d) => { if (verbose) process.stderr.write(`[vite-desktop] ${d}`) })
  viteDesktopProc.stderr.on('data', (d) => process.stderr.write(`[vite-desktop-err] ${d}`))

  const start = Date.now()
  while (Date.now() - start < 30_000) {
    if (await probeViteDesktop()) return { spawned: true }
    await new Promise(r => setTimeout(r, 500))
  }
  try { viteDesktopProc.kill('SIGTERM') } catch {}
  viteDesktopProc = null
  throw new Error('Vite desktop did not become healthy on :5173 within 30s')
}

async function shutdown() {
  if (spawnedProc) {
    spawnedProc.kill('SIGTERM')
    spawnedProc = null
  }
  if (viteProc) {
    viteProc.kill('SIGTERM')
    viteProc = null
  }
  if (viteDesktopProc) {
    viteDesktopProc.kill('SIGTERM')
    viteDesktopProc = null
  }
}

module.exports = { ensureRails, ensureViteWeb, ensureViteDesktop, shutdown, RAILS_PORT, HEALTH_URL, VITE_WEB_PORT, VITE_DESKTOP_PORT }
