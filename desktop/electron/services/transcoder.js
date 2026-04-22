// Desktop transcoder: ffmpeg → HLS (CMAF fmp4 segments).
// Mirrors server/app/services/transcoder_service.rb: three strategies
//   direct_play     — H.264 + AAC source, `-c copy`, zero encode CPU
//   audio_transcode — H.264 + non-AAC audio, copy video, encode audio
//   full_transcode  — HEVC or other, VideoToolbox H.264 encode
//
// Output goes to a session temp directory. The stream:// protocol
// handler (main.js) serves the playlist, init segment, and media
// segments from that directory.

const { spawn, execSync } = require('child_process')
const path = require('path')
const fs = require('fs')
const os = require('os')

function findBinary(name) {
  if (process.resourcesPath) {
    const bundled = path.join(process.resourcesPath, 'ffmpeg', name)
    if (fs.existsSync(bundled)) return bundled
  }

  const vendorDir = process.arch === 'arm64' ? 'ffmpeg-arm64' : 'ffmpeg-x64'
  const devBundled = path.join(__dirname, '..', '..', 'vendor', vendorDir, name)
  if (fs.existsSync(devBundled)) return devBundled

  const envKey = name.toUpperCase() + '_PATH'
  if (process.env[envKey] && fs.existsSync(process.env[envKey])) {
    return process.env[envKey]
  }

  const candidates = [
    `/opt/homebrew/bin/${name}`,
    `/usr/local/bin/${name}`,
    `/usr/bin/${name}`,
  ]
  for (const p of candidates) {
    if (fs.existsSync(p)) return p
  }

  try {
    const resolved = execSync(`which ${name}`, {
      env: { ...process.env, PATH: `${process.env.PATH}:/opt/homebrew/bin:/usr/local/bin` },
    }).toString().trim()
    if (resolved && fs.existsSync(resolved)) return resolved
  } catch {}

  console.warn(`Transcoder: ${name} not found in common locations, falling back to bare name`)
  return name
}

const FFMPEG_PATH = findBinary('ffmpeg')
const FFPROBE_PATH = findBinary('ffprobe')

console.log(`Transcoder: ffmpeg  = ${FFMPEG_PATH}`)
console.log(`Transcoder: ffprobe = ${FFPROBE_PATH}`)

const SESSION_ROOT = path.join(os.tmpdir(), 'caramba-hls-desktop')

let activeProcess = null
let activeSessionId = null
let activeDir = null
let activeFilePath = null
let activeStartTime = 0
let activeForceTranscode = false

function sessionDir(sessionId) {
  return path.join(SESSION_ROOT, sessionId)
}

function wipeDir(dir) {
  if (!dir) return
  try { fs.rmSync(dir, { recursive: true, force: true }) } catch {}
}

function stop() {
  const proc = activeProcess
  const dir = activeDir

  activeProcess = null
  activeSessionId = null
  activeDir = null
  activeFilePath = null
  activeStartTime = 0
  activeForceTranscode = false

  if (proc) {
    try { proc.kill('SIGKILL') } catch {}
  }

  wipeDir(dir)
}

async function probe(filePath) {
  // Open the file in main (which inherits any Files & Folders permission
  // granted to Electron.app via the macOS GUI prompt) and hand the fd to
  // ffprobe as stdin. ffprobe never opens the path itself, so its ad-hoc
  // code signature doesn't fight TCC.
  let fileHandle
  try {
    fileHandle = fs.openSync(filePath, 'r')
  } catch (err) {
    if (err.code === 'EPERM' || err.code === 'EACCES') {
      throw new Error(
        `macOS blocked reading "${filePath}". ` +
        `Grant Electron Files & Folders access (Desktop/Documents/Downloads) ` +
        `in System Settings → Privacy & Security, or move the media out of those folders.`
      )
    }
    throw err
  }

  return new Promise((resolve, reject) => {
    const args = [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      'pipe:0',
    ]
    const proc = spawn(FFPROBE_PATH, args, { stdio: [fileHandle, 'pipe', 'pipe'] })
    // spawn dups the fd into the child; close our copy so ffprobe exiting
    // is observable via EOF on the reader side.
    try { fs.closeSync(fileHandle) } catch {}
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    proc.on('close', code => {
      if (code !== 0) {
        const raw = stderr.trim() || 'no output'
        return reject(new Error(`ffprobe exited with ${code}: ${raw} (file: ${filePath})`))
      }
      try {
        const data = JSON.parse(stdout)
        const videoStream = data.streams?.find(s => s.codec_type === 'video' && s.codec_name !== 'mjpeg')
        const audioStreams = data.streams?.filter(s => s.codec_type === 'audio') || []
        const subtitleStreams = data.streams?.filter(s => s.codec_type === 'subtitle') || []
        const duration = parseFloat(data.format?.duration) || 0

        resolve({
          duration,
          video: videoStream ? {
            codec: videoStream.codec_name,
            width: videoStream.width,
            height: videoStream.height,
            profile: videoStream.profile,
            pix_fmt: videoStream.pix_fmt,
          } : null,
          audioStreams: audioStreams.map(s => ({
            index: s.index,
            codec: s.codec_name,
            channels: s.channels,
            language: s.tags?.language || 'und',
            title: s.tags?.title,
          })),
          subtitleStreams: subtitleStreams.map(s => ({
            index: s.index,
            codec: s.codec_name,
            language: s.tags?.language || 'und',
            title: s.tags?.title,
            isText: ['ass', 'ssa', 'srt', 'subrip', 'webvtt', 'mov_text', 'hdmv_text_subtitle',
              'text', 'ttml', 'microdvd', 'mpl2', 'pjs', 'realtext', 'sami', 'stl',
              'subviewer', 'subviewer1', 'vplayer'].includes(s.codec_name),
          })),
        })
      } catch (e) {
        reject(e)
      }
    })
  })
}

// Browser-decodable video codecs we can remux straight into HLS/fMP4 on
// Electron ≥ 33 (Chromium ≥ 130) on macOS. HEVC (incl. 10-bit, incl. x265
// BluRay rips) is hardware-decoded via VideoToolbox. Anything outside this
// list must be re-encoded to H.264.
const DIRECT_PLAY_VIDEO_CODECS = new Set(['h264', 'hevc', 'h265'])

// One of 'direct_play' | 'audio_transcode' | 'full_transcode'.
function transcodeStrategy(probeResult, audioStreamIndex, burnSubtitleIndex, forceTranscode) {
  if (burnSubtitleIndex != null) return 'full_transcode'
  if (forceTranscode) return 'full_transcode'
  const videoCodec = probeResult.video?.codec
  if (!DIRECT_PLAY_VIDEO_CODECS.has(videoCodec)) return 'full_transcode'
  const audio = probeResult.audioStreams.find(s => s.index === audioStreamIndex)
  const audioCodec = audio?.codec
  return audioCodec === 'aac' ? 'direct_play' : 'audio_transcode'
}

// Resolution-aware bitrate for full_transcode. VideoToolbox H.264 needs
// meaningfully higher bitrate than x264 to reach the same perceptual quality.
function fullTranscodeVideoArgs(probeResult) {
  const width = probeResult.video?.width || 0
  let bitrate, maxrate, bufsize
  if (width >= 3000)      { [bitrate, maxrate, bufsize] = ['20M', '30M', '60M'] }  // 4K
  else if (width >= 1800) { [bitrate, maxrate, bufsize] = ['12M', '18M', '36M'] }  // 1080p
  else if (width >= 1100) { [bitrate, maxrate, bufsize] = ['8M',  '12M', '24M'] }  // 720p
  else                    { [bitrate, maxrate, bufsize] = ['4M',  '6M',  '12M'] }  // SD

  return [
    '-c:v', 'h264_videotoolbox',
    '-b:v', bitrate,
    '-maxrate', maxrate,
    '-bufsize', bufsize,
    '-profile:v', 'high',
    '-pix_fmt', 'yuv420p',
    '-g', '48',
  ]
}

// The child reads the input via fd 3 (inherited stdio slot). The path
// `/dev/fd/3` on macOS/Linux resolves to the already-open fd via a kernel
// dup, so the child binary never invokes open() on the original path — the
// TCC check that rejects ad-hoc signed children is skipped entirely.
const INPUT_FD_PATH = '/dev/fd/3'

function buildArgs(seekTime, outputDir, strategy, probeResult, opts) {
  const args = []
  const burnSub = opts.burnSubtitleIndex != null

  if (strategy === 'full_transcode' && !burnSub) {
    args.push('-hwaccel', 'videotoolbox')
  }

  if (seekTime > 0) {
    args.push('-ss', String(seekTime))
  }
  if (strategy === 'full_transcode') {
    args.push('-analyzeduration', '2000000', '-probesize', '2000000')
  }

  args.push('-i', INPUT_FD_PATH)

  if (burnSub) {
    args.push('-filter_complex',
      `[0:v:0][0:${opts.burnSubtitleIndex}]overlay,scale=iw*sar:ih:flags=lanczos,setsar=1`)
    args.push('-map', opts.audioStreamIndex != null ? `0:${opts.audioStreamIndex}` : '0:a:0')
  } else if (strategy === 'full_transcode') {
    args.push('-vf', 'scale=iw*sar:ih:flags=lanczos,setsar=1')
    args.push('-map', '0:v:0')
    args.push('-map', opts.audioStreamIndex != null ? `0:${opts.audioStreamIndex}` : '0:a:0')
  } else {
    args.push('-map', '0:v:0')
    args.push('-map', opts.audioStreamIndex != null ? `0:${opts.audioStreamIndex}` : '0:a:0')
  }

  switch (strategy) {
    case 'direct_play':
      args.push('-c', 'copy')
      break
    case 'audio_transcode':
      args.push('-c:v', 'copy')
      args.push('-c:a', 'aac', '-b:a', '192k', '-ac', '2')
      break
    case 'full_transcode':
      args.push(...fullTranscodeVideoArgs(probeResult))
      args.push('-c:a', 'aac', '-b:a', '192k', '-ac', '2')
      break
  }

  args.push(
    '-f', 'hls',
    // 2s segments: keeps ffmpeg ahead of playback even under 1x realtime
    // encode. temp_file flag means segments rename atomically so the protocol
    // handler never reads a half-flushed file.
    '-hls_time', '2',
    '-hls_list_size', '0',
    '-hls_playlist_type', 'event',
    '-hls_segment_type', 'fmp4',
    // independent_segments — each segment decodes standalone.
    // temp_file — atomic .tmp + rename so the server never reads a partial file.
    // NO append_list: it makes ffmpeg carry source-coordinate segment numbers
    // and PTS into the output, which desyncs the scrubber from playback after
    // seeks. Without it, each restart produces a clean zero-based playlist.
    '-hls_flags', 'independent_segments+temp_file',
    '-start_number', '0',
    '-hls_fmp4_init_filename', 'init.mp4',
    '-hls_segment_filename', path.join(outputDir, 'segment_%d.m4s'),
    path.join(outputDir, 'playlist.m3u8'),
  )

  args.push('-y', '-nostdin')
  return args
}

// Start transcoding. Probes the file (unless the caller already did),
// spawns a new ffmpeg, then atomically swaps over the active-session state
// and tears down the old process. Keeping `activeDir` set across the whole
// operation means in-flight requests from a previous hls.js instance never
// hit a null session and 400 out — they get served from the new session's
// directory (usually 404 for not-yet-produced segments, which hls.js retries
// cleanly).
async function start(filePath, seekTime = 0, opts = {}) {
  const probeResult = opts.probeResult || await probe(filePath)
  const forceTranscode = !!opts.forceTranscode
  const strategy = transcodeStrategy(probeResult, opts.audioStreamIndex, opts.burnSubtitleIndex, forceTranscode)

  const sessionId = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  const newDir = sessionDir(sessionId)
  fs.mkdirSync(newDir, { recursive: true })

  // Open the input in main so we carry our own TCC authorization; the child
  // reads it via /dev/fd/3 and never triggers the open-by-path TCC check.
  let inputFd
  try {
    inputFd = fs.openSync(filePath, 'r')
  } catch (err) {
    if (err.code === 'EPERM' || err.code === 'EACCES') {
      throw new Error(
        `macOS blocked reading "${filePath}". Electron itself doesn't have ` +
        `Files & Folders access to this folder. Grant it in System Settings → ` +
        `Privacy & Security → Files and Folders (or Full Disk Access), then relaunch.`
      )
    }
    throw err
  }

  const args = buildArgs(seekTime, newDir, strategy, probeResult, opts)

  const proc = spawn(FFMPEG_PATH, args, {
    // stdio slot 3 = the open input fd. ffmpeg sees it as fd 3 and reads
    // from /dev/fd/3. Slot 0/1 are ignored, 2 is stderr for logging.
    stdio: ['ignore', 'ignore', 'pipe', inputFd],
  })
  // Child has its own dup of the fd; close ours so we don't leak descriptors.
  try { fs.closeSync(inputFd) } catch {}

  proc.stderr.on('data', d => {
    const line = d.toString().trim()
    if (line && !line.startsWith('frame=') && !line.startsWith('size=')) {
      console.log(`Transcoder: ${line}`)
    }
  })

  proc.on('close', (code) => {
    if (code && code !== 0 && code !== 255) {
      console.warn(`Transcoder: ffmpeg exited with code ${code}`)
    }
  })

  proc.on('error', (err) => {
    try { require('@sentry/electron/main').captureException(err, { tags: { subsystem: 'transcoder' } }) } catch {}
    console.error(`Transcoder: ffmpeg error — ${err.message}`)
  })

  // Atomic swap: install the new session, then tear down the old one.
  const oldProc = activeProcess
  const oldDir = activeDir

  activeProcess = proc
  activeSessionId = sessionId
  activeDir = newDir
  activeFilePath = filePath
  activeStartTime = seekTime
  activeForceTranscode = forceTranscode

  if (oldProc) {
    try { oldProc.kill('SIGKILL') } catch {}
  }
  if (oldDir && oldDir !== newDir) {
    wipeDir(oldDir)
  }

  console.log(`Transcoder: started ${path.basename(filePath)} @ ${seekTime}s, strategy=${strategy}, forceTranscode=${forceTranscode}, dir=${newDir}`)
  return { sessionId, strategy }
}

async function extractSubtitles(filePath, streamIndex) {
  let inputFd
  try {
    inputFd = fs.openSync(filePath, 'r')
  } catch {
    return null
  }

  return new Promise((resolve) => {
    const args = [
      '-v', 'error',
      '-i', INPUT_FD_PATH,
      '-map', `0:${streamIndex}`,
      '-c:s', 'webvtt',
      '-f', 'webvtt',
      'pipe:1',
    ]
    const proc = spawn(FFMPEG_PATH, args, { stdio: ['ignore', 'pipe', 'pipe', inputFd] })
    try { fs.closeSync(inputFd) } catch {}
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    proc.on('close', code => {
      if (code !== 0 || !stdout.trim()) {
        console.warn(`[Subtitle] ffmpeg extract failed: code=${code}, stderr=${stderr.slice(0, 300)}`)
        return resolve(null)
      }
      resolve(stdout)
    })
    proc.on('error', (err) => {
      try { require('@sentry/electron/main').captureException(err, { tags: { subsystem: 'transcoder' } }) } catch {}
      console.error('[Subtitle] ffmpeg spawn error:', err)
      resolve(null)
    })
  })
}

// ── Accessors for main.js protocol handler ───────────────────────────

function getActiveSessionDir() { return activeDir }
function getActiveSessionId() { return activeSessionId }
function getActiveFilePath() { return activeFilePath }
function getActiveStartTime() { return activeStartTime }
function getActiveForceTranscode() { return activeForceTranscode }
function isActive() { return activeProcess !== null && !activeProcess.killed }

// Whitelist of allowed asset names (prevents directory traversal).
function isValidAssetName(assetName) {
  const safe = path.basename(assetName)
  return safe === 'playlist.m3u8'
    || safe === 'init.mp4'
    || /^segment_\d+\.m4s$/.test(safe)
}

// Resolve a path inside the active session directory. Returns:
//   { status: 'ok', path }          — asset is permitted; caller checks disk
//   { status: 'bad_name' }           — rejected (invalid name, traversal, etc.)
//   { status: 'no_session' }         — no transcoder session active (retryable)
function resolveAsset(assetName) {
  if (!isValidAssetName(assetName)) return { status: 'bad_name' }
  if (!activeDir) return { status: 'no_session' }
  return { status: 'ok', path: path.join(activeDir, path.basename(assetName)) }
}

module.exports = {
  probe,
  start,
  stop,
  extractSubtitles,
  transcodeStrategy,
  getActiveSessionDir,
  getActiveSessionId,
  getActiveFilePath,
  getActiveStartTime,
  getActiveForceTranscode,
  isActive,
  resolveAsset,
}
