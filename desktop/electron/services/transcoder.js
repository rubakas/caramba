// Desktop transcoder: ffmpeg → HLS (CMAF fmp4 segments).
// Mirrors server/app/services/transcoder_service.rb: four strategies
//   direct_play     — file is already browser-playable; skip ffmpeg entirely
//   direct_stream   — codecs OK, container needs remuxing; ffmpeg `-c copy` → fMP4
//   audio_transcode — video OK, non-AAC audio; copy video, encode audio
//   full_transcode  — re-encode video (VideoToolbox H.264)
//
// Card #55: the direct_play tier means no transcoder process at all — the
// renderer pulls the file via the stream:// protocol with Range requests.
// Output for the other three goes to a session temp directory; the stream://
// handler in main.js serves the playlist, init segment, and media segments.

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
        // ffprobe's format_name is comma-separated (e.g. "mov,mp4,m4a,3gp,3g2,mj2"),
        // representing the demuxer family. Used by the direct_play check below.
        const formatName = (data.format?.format_name || '').toLowerCase()

        resolve({
          duration,
          formatName,
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

// Container families a Chromium <video> can demux directly. ffprobe's
// format_name is comma-joined; we substring-match. MKV / TS / AVI / WebM*
// require remuxing because the demuxer either isn't present or doesn't
// support the codec combinations Caramba ships. (* WebM is fine for VP8/VP9
// but those aren't in the direct-play codec list.)
const DIRECT_PLAY_CONTAINERS = ['mp4', 'm4v', 'mov', 'mj2']

function isDirectPlayContainer(formatName) {
  if (!formatName) return false
  return DIRECT_PLAY_CONTAINERS.some(c => formatName.includes(c))
}

// 10-bit pixel formats — Chromium MSE on Electron 33 / macOS plays HEVC
// Main-10 (4K HDR) inconsistently: segments arrive but the decoder produces
// no frames, so the player stalls with bufferStalledError even though the
// buffer has data. Force full_transcode for these so the user gets H.264
// 8-bit output we know plays smoothly.
const TEN_BIT_PIX_FMTS = new Set([
  'yuv420p10le', 'yuv420p10be',
  'yuv422p10le', 'yuv422p10be',
  'yuv444p10le', 'yuv444p10be',
  'p010le', 'p010be',
])

// One of 'direct_play' | 'direct_stream' | 'audio_transcode' | 'full_transcode'.
//
// direct_play   — browser plays the file as-is; no ffmpeg.
// direct_stream — codecs OK but container needs remuxing; ffmpeg `-c copy` → fMP4.
// audio_transcode — video OK, audio re-encoded to AAC stereo.
// full_transcode  — video re-encoded.
function transcodeStrategy(probeResult, audioStreamIndex, burnSubtitleIndex, forceTranscode) {
  if (burnSubtitleIndex != null) return 'full_transcode'
  if (forceTranscode) return 'full_transcode'
  const videoCodec = probeResult.video?.codec
  if (!DIRECT_PLAY_VIDEO_CODECS.has(videoCodec)) return 'full_transcode'
  // 10-bit HEVC: Chromium MSE accepts the codec string but stalls on decode.
  // Re-encode to 8-bit H.264 instead. This is the price of MSE compatibility.
  if ((videoCodec === 'hevc' || videoCodec === 'h265') &&
      TEN_BIT_PIX_FMTS.has(probeResult.video?.pix_fmt)) {
    return 'full_transcode'
  }
  const audio = probeResult.audioStreams.find(s => s.index === audioStreamIndex)
  const audioCodec = audio?.codec
  if (audioCodec !== 'aac') return 'audio_transcode'
  // Codecs are compatible. If the container is also browser-friendly,
  // hand the file to <video> directly — no ffmpeg in the loop. Otherwise
  // remux into fMP4 (DirectStream).
  return isDirectPlayContainer(probeResult.formatName) ? 'direct_play' : 'direct_stream'
}

// Resolution-aware bitrate for full_transcode. VideoToolbox H.264 needs
// meaningfully higher bitrate than x264 to reach the same perceptual quality.
//
// 4K sources are downscaled to 1080p before encoding. VideoToolbox H.264
// at 4K + 10-bit HDR input runs at ~0.7×–1× realtime, which leaves no
// headroom — the player starts before the encoder can build a buffer and
// stalls. Downscaling to 1080p brings encoding speed to >2× realtime and
// avoids stalls. Higher fidelity than that requires libmpv (card #54).
function fullTranscodeVideoArgs(probeResult) {
  const width = probeResult.video?.width || 0
  let bitrate, maxrate, bufsize
  if (width >= 1800)      { [bitrate, maxrate, bufsize] = ['12M', '18M', '36M'] }  // ≥1080p (incl. downscaled 4K)
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

// Whether the source needs to be downscaled to 1080p before encoding.
// True for any source > 1920 wide (4K, ultra-wide cinema rips, etc.).
function needsDownscale(probeResult) {
  return (probeResult.video?.width || 0) > 1920
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
    case 'direct_stream':
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
    // 'direct_play' is unreachable: start() short-circuits before we
    // ever build args — there's no ffmpeg invocation for it.
  }

  // (We tested `-tag:v hvc1` for HEVC copy paths — counter-intuitively, that
  // retag broke playback on Electron 33 / Chromium 130 / macOS for HEVC
  // Main-10 sources: readyState went to 4 with currentTime stuck. ffmpeg's
  // default `hev1` tag plays correctly on this stack via VideoToolbox.
  // The Playwright `@smoke electron plays first movie` test pins this — see
  // tests/specs/electron/smoke.playback.spec.js.)

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
  if (process.env.CARAMBA_TEST_INJECT_FAIL === '1') {
    throw new Error('synthetic-test-failure')
  }
  const probeResult = opts.probeResult || await probe(filePath)
  const forceTranscode = !!opts.forceTranscode
  const strategy = transcodeStrategy(probeResult, opts.audioStreamIndex, opts.burnSubtitleIndex, forceTranscode)

  // direct_play: no ffmpeg in the loop. Tear down any prior transcoder
  // session, record this file as the active source for the stream://
  // protocol's direct-serve branch, and return early. The renderer will
  // load the file via stream://direct?... with byte-range requests handled
  // by main.js — no segmenter, no encoder, no HLS overhead.
  if (strategy === 'direct_play') {
    const oldProc = activeProcess
    const oldDir = activeDir
    activeProcess = null
    activeSessionId = `direct-${Date.now().toString(36)}`
    activeDir = null
    activeFilePath = filePath
    activeStartTime = seekTime
    activeForceTranscode = false
    if (oldProc) { try { oldProc.kill('SIGKILL') } catch {} }
    if (oldDir) wipeDir(oldDir)
    console.log(`Transcoder: direct_play ${path.basename(filePath)} (no ffmpeg)`)
    return { sessionId: activeSessionId, strategy }
  }

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
// Active when an ffmpeg process is running OR when we're in direct_play
// mode (no process, but a file is being served via stream://direct).
function isActive() {
  if (activeProcess !== null && !activeProcess.killed) return true
  return isDirectPlay()
}
function isDirectPlay() {
  return activeProcess === null && activeDir === null && !!activeFilePath
}

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
  // Exported only for unit tests — never call from production code.
  _buildArgs: buildArgs,
  getActiveSessionDir,
  getActiveSessionId,
  getActiveFilePath,
  getActiveStartTime,
  getActiveForceTranscode,
  isActive,
  isDirectPlay,
  resolveAsset,
}
