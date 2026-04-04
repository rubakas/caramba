const { app } = require('electron')
const https = require('https')
const fs = require('fs')
const fsp = require('fs/promises')
const path = require('path')
const os = require('os')
const crypto = require('crypto')
const { execFile } = require('child_process')
const { promisify } = require('util')

const execFileAsync = promisify(execFile)

const GITHUB_REPO = 'rubakas/caramba'
const API_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases/latest`

// Allowed download hosts for update assets — prevents redirect-based SSRF
const ALLOWED_DOWNLOAD_HOSTS = ['github.com', 'objects.githubusercontent.com']

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
 * Returns { version, assetUrl, assetName, sha256 } or null.
 * sha256 is parsed from a CHECKSUMS.txt asset if present (format: "hash  filename").
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

  // Look for a CHECKSUMS.txt asset with SHA256 hashes
  let sha256 = null
  const checksumsAsset = (release.assets || []).find(a =>
    /^checksums?\.txt$/i.test(a.name) || /^sha256/i.test(a.name)
  )
  if (checksumsAsset) {
    try {
      const checksumText = await fetchText(checksumsAsset.browser_download_url)
      // Parse lines like: "abc123def456...  Caramba-1.0.7.dmg"
      for (const line of checksumText.split('\n')) {
        const parts = line.trim().split(/\s+/)
        if (parts.length >= 2 && parts[1] === asset.name && /^[a-f0-9]{64}$/i.test(parts[0])) {
          sha256 = parts[0].toLowerCase()
          break
        }
      }
    } catch (err) {
      console.warn('Updater: failed to fetch checksums —', err.message)
    }
  }

  return {
    version: release.tag_name.replace(/^v/, ''),
    assetUrl: asset.browser_download_url,
    assetName: asset.name,
    sha256,
  }
}

/**
 * Fetch plain text from a URL, following up to 5 redirects.
 */
function fetchText(url, redirects = 5) {
  return new Promise((resolve, reject) => {
    https.get(url, { headers: { 'User-Agent': `Caramba/${app.getVersion()}` } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location && redirects > 0) {
        res.resume()
        return resolve(fetchText(res.headers.location, redirects - 1))
      }
      if (res.statusCode !== 200) {
        res.resume()
        return reject(new Error(`HTTP ${res.statusCode}`))
      }
      let data = ''
      res.on('data', chunk => { data += chunk })
      res.on('end', () => resolve(data))
      res.on('error', reject)
    }).on('error', reject)
  })
}

/**
 * Download an asset URL to a temp file, reporting progress via onProgress({ percent, downloaded, total }).
 * If expectedSha256 is provided, verifies the download hash and throws on mismatch.
 * Returns the local file path.
 */
function downloadUpdate(assetUrl, onProgress, expectedSha256 = null) {
  return new Promise((resolve, reject) => {
    const ext = path.extname(assetUrl.split('?')[0]) || '.download'
    const dest = path.join(os.tmpdir(), `caramba-update-${Date.now()}${ext}`)

    function doRequest(url, remaining) {
      // Security: validate redirect targets are on allowed hosts
      try {
        const parsedUrl = new URL(url)
        if (!ALLOWED_DOWNLOAD_HOSTS.some(h => parsedUrl.hostname === h || parsedUrl.hostname.endsWith('.' + h))) {
          return reject(new Error(`Download blocked: untrusted host ${parsedUrl.hostname}`))
        }
      } catch (e) {
        return reject(new Error(`Invalid download URL: ${url}`))
      }

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
        const hash = crypto.createHash('sha256')

        res.on('data', chunk => {
          downloaded += chunk.length
          hash.update(chunk)
          if (onProgress && total > 0) {
            onProgress({ percent: Math.round((downloaded / total) * 100), downloaded, total })
          }
        })

        res.pipe(out)
        out.on('finish', () => {
          // Verify SHA256 checksum if provided
          if (expectedSha256) {
            const actualHash = hash.digest('hex')
            if (actualHash !== expectedSha256) {
              // Clean up the corrupted/tampered file
              try { fs.unlinkSync(dest) } catch {}
              return reject(new Error(
                `Checksum mismatch! Expected ${expectedSha256}, got ${actualHash}. ` +
                'The download may be corrupted or tampered with.'
              ))
            }
          }
          resolve(dest)
        })
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
