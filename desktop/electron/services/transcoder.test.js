// Unit tests for the desktop transcoder's strategy selector.
// Run via: cd desktop && node --test electron/**/*.test.js
const test = require('node:test')
const assert = require('node:assert/strict')

const { transcodeStrategy, _buildArgs: buildArgs } = require('./transcoder')

function probeResult({
  videoCodec = 'h264',
  audioCodec = 'aac',
  formatName = 'matroska,webm',
  width = 1920,
  pixFmt = 'yuv420p',
  channels = 2,
  bitrate = 0,
  colorTransfer = null,
} = {}) {
  return {
    formatName,
    bitrate,
    video: {
      codec: videoCodec,
      width,
      height: 1080,
      pix_fmt: pixFmt,
      color_transfer: colorTransfer,
    },
    audioStreams: [{ index: 1, codec: audioCodec, channels, language: 'eng' }],
    subtitleStreams: [],
  }
}

test('transcodeStrategy: direct_play for h264 + aac in mp4 container', () => {
  assert.equal(
    transcodeStrategy(probeResult({ formatName: 'mov,mp4,m4a,3gp,3g2,mj2' }), 1, null, false),
    'direct_play'
  )
})

test('transcodeStrategy: direct_play for hevc + aac in mp4 container', () => {
  assert.equal(
    transcodeStrategy(
      probeResult({ videoCodec: 'hevc', audioCodec: 'aac', formatName: 'mov,mp4,m4a,3gp,3g2,mj2' }),
      1, null, false
    ),
    'direct_play'
  )
})

test('transcodeStrategy: direct_stream when codecs OK but container is MKV', () => {
  assert.equal(
    transcodeStrategy(probeResult({ formatName: 'matroska,webm' }), 1, null, false),
    'direct_stream'
  )
})

test('transcodeStrategy: audio_transcode for non-aac audio', () => {
  assert.equal(
    transcodeStrategy(
      probeResult({ videoCodec: 'hevc', audioCodec: 'ac3' }),
      1, null, false
    ),
    'audio_transcode'
  )
})

test('transcodeStrategy: audio_transcode for eac3 audio in mp4 container', () => {
  // Codec mismatch wins over container fitness — eac3 still has to be transcoded.
  assert.equal(
    transcodeStrategy(
      probeResult({ videoCodec: 'h264', audioCodec: 'eac3', formatName: 'mov,mp4,m4a,3gp,3g2,mj2' }),
      1, null, false
    ),
    'audio_transcode'
  )
})

test('transcodeStrategy: full_transcode for unsupported video codec', () => {
  assert.equal(
    transcodeStrategy(probeResult({ videoCodec: 'vc1' }), 1, null, false),
    'full_transcode'
  )
})

test('transcodeStrategy: full_transcode when burning a bitmap subtitle', () => {
  // Bitmap subs require pixel composition, which forces re-encode.
  assert.equal(
    transcodeStrategy(probeResult(), 1, /* burnSubtitleIndex */ 3, false),
    'full_transcode'
  )
})

test('transcodeStrategy: forceTranscode overrides everything (incl. mp4 direct_play)', () => {
  assert.equal(
    transcodeStrategy(
      probeResult({ formatName: 'mov,mp4,m4a,3gp,3g2,mj2' }),
      1, null, /* forceTranscode */ true
    ),
    'full_transcode'
  )
})

test('transcodeStrategy: 8-bit HEVC + AAC in mp4 → direct_play (no encode CPU)', () => {
  // 8-bit HEVC inside mp4 is browser-decodable on Chromium 130 / macOS via
  // VideoToolbox — straight to <video>, no ffmpeg.
  assert.equal(
    transcodeStrategy(
      probeResult({
        videoCodec: 'hevc',
        audioCodec: 'aac',
        formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
        width: 3840,
        pixFmt: 'yuv420p',
      }),
      1, null, false
    ),
    'direct_play'
  )
})

test('transcodeStrategy: 10-bit HEVC (Main 10) → full_transcode regardless of container', () => {
  // Pinned by the @smoke electron Playwright test on Aladdin (4K HEVC HDR).
  // Chromium MSE on Electron 33 accepts the codec string but stalls on the
  // decode. Re-encode to 8-bit H.264 to keep playback smooth.
  for (const fmt of ['mov,mp4,m4a,3gp,3g2,mj2', 'matroska,webm']) {
    assert.equal(
      transcodeStrategy(
        probeResult({
          videoCodec: 'hevc',
          audioCodec: 'aac',
          formatName: fmt,
          width: 3840,
          pixFmt: 'yuv420p10le',
        }),
        1, null, false
      ),
      'full_transcode',
      `expected full_transcode for 10-bit HEVC in ${fmt}`
    )
  }
})

test('transcodeStrategy: 10-bit HEVC + non-aac audio still full_transcode (not audio_transcode)', () => {
  // Without the 10-bit guard this would have routed to audio_transcode —
  // copying the broken video stream and only re-encoding audio. Make sure
  // the 10-bit check fires BEFORE the audio check.
  assert.equal(
    transcodeStrategy(
      probeResult({
        videoCodec: 'hevc',
        audioCodec: 'truehd',
        formatName: 'matroska,webm',
        width: 3840,
        pixFmt: 'yuv420p10le',
      }),
      1, null, false
    ),
    'full_transcode'
  )
})

test('transcodeStrategy: 4K HEVC in MKV remuxes via direct_stream (still no encode CPU)', () => {
  // Same 4K HEVC in MKV: container needs remux but ffmpeg copies the elementary
  // streams without re-encoding. CPU cost is ~5%, plays smooth.
  assert.equal(
    transcodeStrategy(
      probeResult({
        videoCodec: 'hevc',
        audioCodec: 'aac',
        formatName: 'matroska,webm',
        width: 3840,
      }),
      1, null, false
    ),
    'direct_stream'
  )
})

// ── ffmpeg arg builder ────────────────────────────────────────────────

function findArg(args, flag) {
  const idx = args.indexOf(flag)
  return idx === -1 ? null : args[idx + 1]
}

test('buildArgs: HEVC copy does NOT force hvc1 tag (Electron 33 / Chromium 130 plays the default `hev1` correctly via VideoToolbox; forcing hvc1 broke the @smoke playback test)', () => {
  const probe = {
    formatName: 'matroska,webm',
    video: { codec: 'hevc', width: 3840, height: 2160, pix_fmt: 'yuv420p10le' },
    audioStreams: [{ index: 1, codec: 'aac', channels: 2, language: 'eng' }],
  }
  const args = buildArgs(0, '/tmp/out', 'direct_stream', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-tag:v'), null, 'must NOT force hvc1 — see comment in buildArgs')
})

test('buildArgs: H.264 copy does not add a video tag', () => {
  const probe = {
    formatName: 'matroska,webm',
    video: { codec: 'h264', width: 1920, height: 1080, pix_fmt: 'yuv420p' },
    audioStreams: [{ index: 1, codec: 'aac', channels: 2, language: 'eng' }],
  }
  const args = buildArgs(0, '/tmp/out', 'direct_stream', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-tag:v'), null)
})

test('buildArgs: uses 6-second HLS segments', () => {
  const probe = probeResult({ videoCodec: 'hevc', audioCodec: 'aac' })
  const args = buildArgs(0, '/tmp/out', 'direct_stream', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-hls_time'), '6')
})

// ── Source-aware video bitrate (full_transcode) ──────────────────────

test('buildArgs full_transcode: targets source bitrate when below the cap', () => {
  const probe = probeResult({ videoCodec: 'vc1', width: 1920, bitrate: 8_000_000 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:v'), '8000000')
  assert.equal(findArg(args, '-maxrate'), '12000000')
  assert.equal(findArg(args, '-bufsize'), '24000000')
})

test('buildArgs full_transcode: caps 1080p source at 20M ceiling', () => {
  const probe = probeResult({ videoCodec: 'vc1', width: 1920, bitrate: 50_000_000 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:v'), '20000000')
})

test('buildArgs full_transcode: 4K source caps at 40M', () => {
  const probe = probeResult({ videoCodec: 'vc1', width: 3840, bitrate: 100_000_000 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:v'), '40000000')
})

test('buildArgs full_transcode: falls back to cap when probe has no bitrate', () => {
  const probe = probeResult({ videoCodec: 'vc1', width: 1920, bitrate: 0 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:v'), '20000000')
})

test('buildArgs full_transcode: includes -allow_sw 1', () => {
  const probe = probeResult({ videoCodec: 'vc1', width: 1920, bitrate: 8_000_000 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-allow_sw'), '1')
})

// ── Multi-channel AAC ────────────────────────────────────────────────

test('buildArgs audio_transcode: stereo source → 192k AAC, no -ac flag', () => {
  const probe = probeResult({ videoCodec: 'h264', audioCodec: 'ac3', channels: 2 })
  const args = buildArgs(0, '/tmp/out', 'audio_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:a'), '192k')
  assert.equal(findArg(args, '-ac'), null, 'stereo source should not force a layout change')
})

test('buildArgs audio_transcode: 5.1 source → 384k AAC, no downmix', () => {
  const probe = probeResult({ videoCodec: 'h264', audioCodec: 'eac3', channels: 6 })
  const args = buildArgs(0, '/tmp/out', 'audio_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:a'), '384k')
  assert.equal(findArg(args, '-ac'), null)
})

test('buildArgs audio_transcode: 7.1 source → 384k AAC, downmixed to 6 channels', () => {
  const probe = probeResult({ videoCodec: 'h264', audioCodec: 'truehd', channels: 8 })
  const args = buildArgs(0, '/tmp/out', 'audio_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-b:a'), '384k')
  assert.equal(findArg(args, '-ac'), '6')
})

// ── HDR tonemap (PQ/HLG → SDR) ───────────────────────────────────────

test('buildArgs full_transcode: HDR PQ source prepends tonemap chain to -vf', () => {
  const probe = probeResult({
    videoCodec: 'hevc', pixFmt: 'yuv420p10le', width: 3840,
    colorTransfer: 'smpte2084', bitrate: 16_000_000,
  })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  const vf = findArg(args, '-vf')
  assert.match(vf, /zscale=t=linear:npl=100/)
  assert.match(vf, /tonemap=tonemap=hable/)
  assert.match(vf, /format=yuv420p$/)
  assert.equal(findArg(args, '-color_primaries'), 'bt709')
  assert.equal(findArg(args, '-color_trc'), 'bt709')
  assert.equal(findArg(args, '-colorspace'), 'bt709')
  assert.equal(findArg(args, '-color_range'), 'tv')
})

test('buildArgs full_transcode: HLG source also tonemaps', () => {
  const probe = probeResult({
    videoCodec: 'hevc', pixFmt: 'yuv420p10le', width: 3840,
    colorTransfer: 'arib-std-b67',
  })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.match(findArg(args, '-vf'), /tonemap=tonemap=hable/)
})

test('buildArgs full_transcode: SDR (bt709) source skips tonemap', () => {
  const probe = probeResult({ videoCodec: 'vc1', colorTransfer: 'bt709' })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  const vf = findArg(args, '-vf')
  assert.doesNotMatch(vf, /zscale|tonemap/)
  assert.equal(findArg(args, '-color_primaries'), null,
    'SDR sources must not be tagged with bt709 explicitly')
})

test('buildArgs full_transcode: missing color_transfer is treated as SDR', () => {
  const probe = probeResult({ videoCodec: 'vc1', colorTransfer: null })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.doesNotMatch(findArg(args, '-vf'), /zscale|tonemap/)
})

test('buildArgs full_transcode: HDR 4K downscales to 1080p before tonemap (CPU mitigation)', () => {
  const probe = probeResult({
    videoCodec: 'hevc', pixFmt: 'yuv420p10le', width: 3840,
    colorTransfer: 'smpte2084',
  })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  const vf = findArg(args, '-vf')
  assert.match(vf, /scale=-2:1080:flags=lanczos/)
  assert.ok(vf.indexOf('scale=-2:1080') < vf.indexOf('zscale=t=linear'),
    'downscale must precede tonemap')
})

test('buildArgs full_transcode: HDR 1080p does NOT add downscale', () => {
  const probe = probeResult({
    videoCodec: 'hevc', pixFmt: 'yuv420p10le', width: 1920,
    colorTransfer: 'smpte2084',
  })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.doesNotMatch(findArg(args, '-vf'), /scale=-2:1080/)
})

test('buildArgs full_transcode: SDR 4K does NOT downscale', () => {
  const probe = probeResult({ videoCodec: 'vc1', colorTransfer: 'bt709', width: 3840 })
  const args = buildArgs(0, '/tmp/out', 'full_transcode', probe, { audioStreamIndex: 1 })
  assert.doesNotMatch(findArg(args, '-vf'), /scale=-2:1080/)
})

test('audioTranscodeArgs: uses conservative aresample=async=1', () => {
  const probe = probeResult({ channels: 6 })
  const args = buildArgs(0, '/tmp/out', 'audio_transcode', probe, { audioStreamIndex: 1 })
  assert.equal(findArg(args, '-af'), 'aresample=async=1')
  assert.equal(findArg(args, '-ar'), '48000')
})

