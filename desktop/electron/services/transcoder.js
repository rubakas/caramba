// Transcoder service: ffmpeg HEVC MKV → H.264+AAC fragmented MP4 via pipe.
// Uses macOS VideoToolbox for hardware-accelerated decode + encode.

const { spawn, execSync } = require('child_process')
const path = require('path')
const fs = require('fs')
const { PassThrough } = require('stream')

// In packaged Electron apps, PATH is minimal (/usr/bin:/bin:/usr/sbin:/sbin).
// ffmpeg/ffprobe installed via Homebrew won't be found. Resolve the full path.
// Priority: bundled binary > env var > common install locations > which fallback
function findBinary(name) {
  // 1. Bundled binary in extraResources (packaged app)
  if (process.resourcesPath) {
    const bundled = path.join(process.resourcesPath, 'ffmpeg', name)
    if (fs.existsSync(bundled)) return bundled
  }

  // 2. Bundled binary relative to project root (dev mode)
  const vendorDir = process.arch === 'arm64' ? 'ffmpeg-arm64' : 'ffmpeg-x64'
  const devBundled = path.join(__dirname, '..', '..', 'vendor', vendorDir, name)
  if (fs.existsSync(devBundled)) return devBundled

  // 3. Explicit env var override
  const envKey = name.toUpperCase() + '_PATH'
  if (process.env[envKey] && fs.existsSync(process.env[envKey])) {
    return process.env[envKey]
  }

  // 4. Common install locations
  const candidates = [
    `/opt/homebrew/bin/${name}`,   // Homebrew (Apple Silicon)
    `/usr/local/bin/${name}`,       // Homebrew (Intel) / manual install
    `/usr/bin/${name}`,             // System
  ]
  for (const p of candidates) {
    if (fs.existsSync(p)) return p
  }

  // 5. Try `which` with expanded PATH (works in dev, may fail packaged)
  try {
    const resolved = execSync(`which ${name}`, {
      env: { ...process.env, PATH: `${process.env.PATH}:/opt/homebrew/bin:/usr/local/bin` },
    }).toString().trim()
    if (resolved && fs.existsSync(resolved)) return resolved
  } catch {}

  // 6. Fallback to bare name (will fail in spawn if not on PATH)
  console.warn(`Transcoder: ${name} not found in common locations, falling back to bare name`)
  return name
}

const FFMPEG_PATH = findBinary('ffmpeg')
const FFPROBE_PATH = findBinary('ffprobe')

console.log(`Transcoder: ffmpeg  = ${FFMPEG_PATH}`)
console.log(`Transcoder: ffprobe = ${FFPROBE_PATH}`)

let activeProcess = null
let activeStream = null
let activeFilePath = null
let activeStartTime = 0

function stop() {
  const proc = activeProcess
  const stream = activeStream

  activeProcess = null
  activeStream = null
  activeFilePath = null
  activeStartTime = 0

  if (proc) {
    try { proc.stdout.unpipe() } catch {}
    try { proc.stdout.destroy() } catch {}
    try { proc.kill('SIGKILL') } catch {}
  }
  if (stream) {
    try { stream.destroy() } catch {}
  }
}

/**
 * Probe a media file for duration, video/audio codec info, and subtitle tracks.
 */
async function probe(filePath) {
  return new Promise((resolve, reject) => {
    const args = [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      filePath,
    ]
    const proc = spawn(FFPROBE_PATH, args, { stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    proc.stdout.on('data', d => { stdout += d })
    proc.stderr.on('data', d => { stderr += d })
    proc.on('close', code => {
      if (code !== 0) return reject(new Error(`ffprobe exited with ${code}: ${stderr.trim() || 'no output'} (file: ${filePath})`))
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

/**
 * Start transcoding a file. Returns a readable stream of fragmented MP4.
 * Uses hardware acceleration when available (VideoToolbox on macOS).
 * Falls back to software encoding if hwaccel is unavailable.
 * @param {string} filePath
 * @param {number} seekTime
 * @param {object} [opts]
 * @param {number} [opts.audioStreamIndex] - absolute stream index for audio (from probe)
 * @param {number} [opts.burnSubtitleIndex] - absolute stream index for bitmap subtitle to burn in
 */
function start(filePath, seekTime = 0, opts = {}) {
  stop()

  const args = []
  const burnSub = opts.burnSubtitleIndex != null

  // Hardware-accelerated decoding (VideoToolbox).
  // When burning in bitmap subtitles we need the overlay filter which
  // operates on software frames, so skip hwaccel to avoid an extra
  // download/upload round-trip that can cause format mismatches.
  if (!burnSub) {
    args.push('-hwaccel', 'videotoolbox')
  }

  // Seek before input for fast seeking
  if (seekTime > 0) {
    args.push('-ss', String(seekTime))
  }

  // No readrate throttle: let ffmpeg transcode as fast as the hardware
  // encoder allows. The player's MSE SourceBuffer handles flow control,
  // and removing the limit prevents buffer underruns on slower Macs.

  args.push('-i', filePath)

  if (burnSub) {
    // Burn bitmap subtitle into the video via overlay filter.
    // The filter graph takes the first video stream and the selected
    // subtitle stream, composites them, and outputs a single video.
    args.push(
      '-filter_complex', `[0:v:0][0:${opts.burnSubtitleIndex}]overlay`,
    )
    // Map audio separately (filter_complex handles video output)
    if (opts.audioStreamIndex != null) {
      args.push('-map', `0:${opts.audioStreamIndex}`)
    } else {
      args.push('-map', '0:a:0')
    }
  } else {
    // Map first real video (skip cover art/mjpeg)
    args.push('-map', '0:v:0')

    // Map audio: use specified stream index, or fall back to first audio
    if (opts.audioStreamIndex != null) {
      args.push('-map', `0:${opts.audioStreamIndex}`)
    } else {
      args.push('-map', '0:a:0')
    }
  }

  // Video encoding: H.264 via VideoToolbox
  // -g 48 = keyframe every 2s at 24fps. Without this, VideoToolbox
  // inserts keyframes too frequently (~0.5s) which fragments the MP4
  // excessively and causes higher memory usage in the browser's MSE
  // SourceBuffer.  Matches the server-side transcoder setting.
  args.push(
    '-c:v', 'h264_videotoolbox',
    '-b:v', '4M',
    '-maxrate', '6M',
    '-bufsize', '12M',
    '-profile:v', 'high',
    '-pix_fmt', 'yuv420p',
    '-g', '48',
  )

  // Audio: AAC stereo
  args.push('-c:a', 'aac', '-b:a', '192k', '-ac', '2')

  // Output: fragmented MP4 to stdout
  args.push(
    '-f', 'mp4',
    '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
    'pipe:1',
  )

  // Overwrite, no stdin
  args.push('-y')

  const proc = spawn(FFMPEG_PATH, args, {
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  // Log ffmpeg stderr for debugging (errors only, skip progress lines)
  proc.stderr.on('data', d => {
    const line = d.toString().trim()
    if (line && !line.startsWith('frame=') && !line.startsWith('size=')) {
      console.log(`Transcoder: ${line}`)
    }
  })

  const stream = new PassThrough()

  // Catch stream errors so they don't become uncaught exceptions
  // (e.g. write-after-end from lingering pipe data during stop/restart)
  stream.on('error', () => {})

  proc.stdout.pipe(stream)

  proc.on('close', (code) => {
    if (code && code !== 0 && code !== 255) {
      console.warn(`Transcoder: ffmpeg exited with code ${code}`)
    }
    if (!stream.destroyed && stream.writable) {
      stream.end()
    }
  })

  proc.on('error', (err) => {
    console.error(`Transcoder: ffmpeg error — ${err.message}`)
    stream.destroy(err)
  })

  activeProcess = proc
  activeStream = stream
  activeFilePath = filePath
  activeStartTime = seekTime

  console.log(`Transcoder: started ${path.basename(filePath)} @ ${seekTime}s`)
  return stream
}

/**
 * Extract text subtitles from a file and convert to WebVTT.
 * Returns the WebVTT content as a string, or null if no text subs found.
 */
async function extractSubtitles(filePath, streamIndex) {
  return new Promise((resolve) => {
    const args = [
      '-v', 'quiet',
      '-i', filePath,
      '-map', `0:${streamIndex}`,
      '-c:s', 'webvtt',
      '-f', 'webvtt',
      'pipe:1',
    ]
    const proc = spawn(FFMPEG_PATH, args, { stdio: ['ignore', 'pipe', 'pipe'] })
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
      console.error('[Subtitle] ffmpeg spawn error:', err)
      resolve(null)
    })
  })
}

function getActiveFilePath() { return activeFilePath }
function getActiveStartTime() { return activeStartTime }
function getActiveStream() { return activeStream }
function isActive() { return activeProcess !== null && !activeProcess.killed }

module.exports = { probe, start, stop, extractSubtitles, getActiveFilePath, getActiveStartTime, getActiveStream, isActive }
