const { app } = require('electron')
const https = require('https')
const fs = require('fs')
const fsp = require('fs/promises')
const path = require('path')
const os = require('os')
const { execFile } = require('child_process')
const { promisify } = require('util')

const execFileAsync = promisify(execFile)

const GITHUB_REPO = 'rubakas/caramba'
const API_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`

/**
 * Parse a version string like "1.0.5" into an integer tuple [1, 0, 5].
 * Returns null if the string is not a valid semver.
 */
function parseVersion(str) {
  const parts = str.replace(/^v/, '').split('.').map(Number)
  if (parts.length !== 3 || parts.some(isNaN)) return null
  return parts
}

/**
 * Returns true if `a` is greater than `b` (both [major, minor, patch] tuples).
 */
function isNewer(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] > b[i]) return true
    if (a[i] < b[i]) return false
  }
  return false
}

/**
 * Fetch JSON from a URL, following up to 5 redirects.
 */
function fetchJson(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': `Caramba/${app.getVersion()}` } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume() // drain to free the socket
        return resolve(fetchJson(res.headers.location, redirects - 1))
      }
      if (res.statusCode !== 200) {
        res.resume()
        return reject(new Error(`HTTP ${res.statusCode}`))
      }
      let data = ''
      res.on('data', chunk => { data += chunk })
      res.on('end', () => {
        try { resolve(JSON.parse(data)) } catch (e) { reject(e) }
      })
      res.on('error', reject)
    }).on('error', reject)
  })
}

/**
 * Check GitHub releases for a newer version.
 * Returns { version, assetUrl, assetName } or null.
 */
async function checkForUpdate() {
  const release = await fetchJson(API_URL)

  const latestParsed = parseVersion(release.tag_name)
  const currentParsed = parseVersion(app.getVersion())

  if (!latestParsed || !currentParsed) return null
  if (!isNewer(latestParsed, currentParsed)) return null

  // Select the right asset for the current platform
  const ext = process.platform === 'darwin' ? '.dmg' : '.AppImage'
  const asset = (release.assets || []).find(a => a.name.endsWith(ext))
  if (!asset) return null

  return {
    version: release.tag_name.replace(/^v/, ''),
    assetUrl: asset.browser_download_url,
    assetName: asset.name,
  }
}

/**
 * Download an asset URL to a temp file, reporting progress via onProgress({ percent, downloaded, total }).
 * Returns the local file path.
 */
function downloadUpdate(assetUrl, onProgress) {
  return new Promise((resolve, reject) => {
    const ext = path.extname(assetUrl.split('?')[0]) || '.download'
    const dest = path.join(os.tmpdir(), `caramba-update-${Date.now()}${ext}`)

    function doRequest(url, remaining) {
      https.get(url, { headers: { 'User-Agent': `Caramba/${app.getVersion()}` } }, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && remaining > 0) {
          res.resume() // drain to free the socket
          return doRequest(res.headers.location, remaining - 1)
        }
        if (res.statusCode !== 200) {
          res.resume()
          return reject(new Error(`Download failed: HTTP ${res.statusCode}`))
        }

        const total = parseInt(res.headers['content-length'] || '0', 10)
        let downloaded = 0
        const out = fs.createWriteStream(dest)

        res.on('data', chunk => {
          downloaded += chunk.length
          if (onProgress && total > 0) {
            onProgress({ percent: Math.round((downloaded / total) * 100), downloaded, total })
          }
        })

        res.pipe(out)
        out.on('finish', () => resolve(dest))
        out.on('error', reject)
        res.on('error', reject)
      }).on('error', reject)
    }

    doRequest(assetUrl, 5)
  })
}

/**
 * Install the downloaded file and relaunch the app.
 * On macOS: mount DMG, copy .app to /Applications/, unmount, relaunch.
 * On Linux: replace the current AppImage executable in-place, relaunch.
 */
async function installUpdate(filePath) {
  if (process.platform === 'darwin') {
    await installMac(filePath)
  } else if (process.platform === 'linux') {
    await installLinux(filePath)
  } else {
    throw new Error(`Unsupported platform: ${process.platform}`)
  }

  app.relaunch()
  app.quit()
}

async function installMac(dmgPath) {
  // Mount the DMG
  const { stdout } = await execFileAsync('hdiutil', ['attach', '-nobrowse', '-quiet', dmgPath])

  // Parse mount point: last tab-delimited field of last non-empty line
  const mountPoint = stdout.trim().split('\n').pop().split('\t').pop().trim()
  if (!mountPoint || !mountPoint.startsWith('/')) {
    throw new Error(`Could not determine DMG mount point from: ${stdout}`)
  }

  try {
    // Find the .app bundle inside the mount
    const entries = await fsp.readdir(mountPoint)
    const appName = entries.find(e => e.endsWith('.app'))
    if (!appName) throw new Error(`No .app bundle found in ${mountPoint}`)

    const appSrc = path.join(mountPoint, appName)
    const appDest = path.join('/Applications', appName)

    // Copy to /Applications (overwrites existing)
    await execFileAsync('cp', ['-Rf', appSrc, appDest])
  } finally {
    // Always unmount, even if copy failed
    await execFileAsync('hdiutil', ['detach', mountPoint, '-quiet']).catch(() => {})
  }
}

async function installLinux(appImagePath) {
  const target = process.execPath
  try {
    fs.copyFileSync(appImagePath, target)
    fs.chmodSync(target, 0o755)
  } catch (err) {
    if (err.code === 'EACCES') {
      throw new Error('Insufficient permissions to update. Please reinstall manually.')
    }
    throw err
  }
}

module.exports = { checkForUpdate, downloadUpdate, installUpdate }
