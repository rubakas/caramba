/**
 * DeviceProfile builders — declarative codec contract sent to the Rails
 * server on every POST /api/playback/start. The server matches the file's
 * probed streams against the profile to decide whether to direct-play,
 * direct-stream (remux), audio-transcode, or full-transcode.
 *
 * Schema mirrors Jellyfin's DeviceProfile (subset):
 *   - DirectPlayProfiles: containers + codecs the client decodes as-is.
 *     Comma-joined CSVs per Type. Server splits on comma + case-insensitive
 *     equality (mirroring ContainerHelper.ContainsContainer).
 *   - TranscodingProfiles: target containers + codecs the server may
 *     transcode TO when a direct path doesn't match.
 *   - SubtitleProfiles: subtitle format + delivery method.
 *       External — server serves a sidecar (VTT) the client overlays.
 *       Embed    — client renders the embedded sub stream itself (mpv,
 *                   ExoPlayer); server leaves it in the muxed stream.
 *       (Burn isn't listed by clients; server falls back to burn-in when
 *        no Embed/External entry covers the file's subtitle format.)
 *   - CodecProfiles: per-codec constraints (e.g. HEVC bit-depth cap on
 *     Electron 33 / Chromium 130 MSE).
 *   - MaxStaticBitrate: ceiling for direct play of static (non-HLS) streams.
 *
 * One profile per client; built once at construction time from runtime
 * capability probes (MSE for browsers, hardcoded for ExoPlayer/native).
 * libmpv-derived profile generation will replace the libvlc placeholder
 * once Deliverable B lands.
 */

function probe(type) {
  if (typeof MediaSource === 'undefined' || typeof MediaSource.isTypeSupported !== 'function') return false
  try { return MediaSource.isTypeSupported(type) } catch { return false }
}

function isElectronRuntime() {
  if (typeof navigator === 'undefined') return false
  return /\bElectron\b/.test(navigator.userAgent || '')
}

// HEVC level_idc values we probe. Mirrors ffprobe's level field exactly,
// so the server's VideoLevel comparator matches the LessThanEqual cap
// emitted in CodecProfiles.
//   120 = 4.0  (4K @ 30fps)
//   150 = 5.0  (4K @ 60fps main-tier)
//   153 = 5.1  (4K @ 60fps high-tier)
//   156 = 5.2  (8K)
const HEVC_LEVELS = [120, 150, 153, 156]

// Probe each level for both Main and Main 10 profiles using both `hvc1`
// (mp4 sample entry) and `hev1` (raw HEVC NAL) tags — Chrome accepts both
// but only one form per platform survives MSE strict mode.
function highestHevcLevel(profileTag /* '1.6' | '2.4' */) {
  let best = 0
  for (const lvl of HEVC_LEVELS) {
    const hvc1 = `video/mp4; codecs="hvc1.${profileTag}.L${lvl}.B0"`
    const hev1 = `video/mp4; codecs="hev1.${profileTag}.L${lvl}.B0"`
    if (probe(hvc1) || probe(hev1)) best = lvl
  }
  return best
}

// HDR decode capability via the W3C Media Capabilities API. Lets us
// distinguish "decoder accepts the bitstream" (canPlayType) from "system
// can actually display HDR" (decodingInfo's powerEfficient + supported
// against PQ + Rec.2020). When this returns false, the client emits a
// VideoRangeType:Equals:SDR CodecProfile so the server tonemaps HDR
// sources instead of letting them direct-play to a non-HDR display.
async function probeHdrSupport() {
  if (typeof navigator === 'undefined' || !navigator.mediaCapabilities?.decodingInfo) return false
  try {
    const info = await navigator.mediaCapabilities.decodingInfo({
      type: 'media-source',
      video: {
        contentType: 'video/mp4; codecs="hvc1.2.4.L150.B0"',
        width: 3840, height: 2160, bitrate: 20_000_000, framerate: 60,
        hdrMetadataType: 'smpteSt2086',
        colorGamut: 'rec2020',
        transferFunction: 'pq',
      },
    })
    return !!info.supported
  } catch { return false }
}

// Cached HDR probe — decodingInfo is async; we kick off the probe lazily
// and read the resolved value on subsequent calls. First profile build of
// a session may see `null` (treat as conservative SDR-only) until the
// promise settles, but startup playback is always strategy-driven by the
// server, so a slightly conservative first profile is acceptable.
let _hdrSupported = null
let _hdrProbePromise = null
function hdrSupportedSync() {
  if (_hdrSupported !== null) return _hdrSupported
  if (!_hdrProbePromise) {
    _hdrProbePromise = probeHdrSupport().then(v => { _hdrSupported = v })
  }
  return false
}

const TRANSCODE_TARGET_CONTAINER = 'mp4'
const TRANSCODE_TARGET_VIDEO = 'h264'
const TRANSCODE_TARGET_AUDIO = 'aac'
const TRANSCODE_TARGET_MAX_AUDIO_CHANNELS = '6'

/**
 * Browser MSE profile. Probes HTMLMediaElement.canPlayType() / MSE
 * isTypeSupported() to detect which codecs the active <video> element
 * can decode in fMP4 segments.
 */
export function buildBrowserProfile() {
  const h264 = probe('video/mp4; codecs="avc1.640028"')

  const hevc8MaxLevel = highestHevcLevel('1.6')
  // Electron 33 / Chromium 130 MSE accepts the codec string but stalls on
  // 10-bit playback (segments arrive, decoder produces no frames). Real
  // browsers (Safari, Chrome 107+) decode 10-bit HEVC reliably.
  const hevc10MaxLevel = isElectronRuntime() ? 0 : highestHevcLevel('2.4')

  // AV1 — Main profile, 4K SDR (.05M.08), 4K HDR (.05M.10), 8K SDR
  // (.09M.08). Chrome 70+, Firefox 67+, Safari 17.4+ on Apple Silicon.
  const av1 = probe('video/mp4; codecs="av01.0.05M.08"') ||
              probe('video/mp4; codecs="av01.0.09M.08"')
  const av1Hdr = probe('video/mp4; codecs="av01.0.05M.10"')

  // VP9 — Profile 0 (8-bit), Profile 2 (10-bit HDR). Chrome universal,
  // Safari 14+, Firefox.
  const vp9 = probe('video/mp4; codecs="vp09.00.50.08"')
  const vp9Hdr = probe('video/mp4; codecs="vp09.02.51.10"')

  const audioFlags = {
    aac:    true, // unconditional — every MSE-capable browser supports it
    ac3:    probe('audio/mp4; codecs="ac-3"'),
    eac3:   probe('audio/mp4; codecs="ec-3"'),
    flac:   probe('audio/mp4; codecs="flac"'),
    mp3:    probe('audio/mp4; codecs="mp4a.40.34"') || probe('audio/mp4; codecs="mp3"'),
    opus:   probe('audio/mp4; codecs="opus"'),
    // DTS / DTS-HD work in Chrome with the "DTS audio codec extension"
    // shipped in Win 11. Negative on most builds; we probe anyway so
    // capable installs avoid an audio_transcode.
    dts:    probe('audio/mp4; codecs="dts"') || probe('audio/mp4; codecs="dtsc"'),
    dtshd:  probe('audio/mp4; codecs="dtsh"'),
    vorbis: probe('audio/webm; codecs="vorbis"'),
  }

  const videoCodecs = []
  if (h264)             videoCodecs.push('h264')
  if (hevc8MaxLevel)    videoCodecs.push('hevc', 'h265')
  if (av1 || av1Hdr)    videoCodecs.push('av1')
  if (vp9 || vp9Hdr)    videoCodecs.push('vp9')

  const audioCodecs = Object.entries(audioFlags).filter(([_, v]) => v).map(([k]) => k)

  // Containers MSE / <video> can demux directly. mp4 family only — MKV,
  // AVI, TS, WebM require remuxing on the server (direct_stream).
  const directPlayContainer = 'mp4,m4v,mov,mj2'

  const profile = {
    Name: 'caramba-browser',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [
      { Container: directPlayContainer, Type: 'Video',
        VideoCodec: videoCodecs.join(','), AudioCodec: audioCodecs.join(',') },
      { Container: directPlayContainer, Type: 'Audio',
        AudioCodec: audioCodecs.join(',') },
    ],
    TranscodingProfiles: [
      { Container: TRANSCODE_TARGET_CONTAINER, Type: 'Video', Protocol: 'hls',
        VideoCodec: TRANSCODE_TARGET_VIDEO, AudioCodec: TRANSCODE_TARGET_AUDIO,
        MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS },
    ],
    SubtitleProfiles: [
      // Browsers render WebVTT via <track>. Server extracts ANY source
      // subtitle codec (incl. ASS/SSA/SubRip) to VTT and serves it at
      // /api/playback/subtitles?session=...
      //
      // ASS/SSA styling (fonts, positions, karaoke) is lost in the VTT
      // conversion. Client-side libass-wasm rendering would preserve it
      // — see follow-up task in the plan file.
      { Format: 'vtt', Method: 'External' },
    ],
    CodecProfiles: [],
    ContainerProfiles: [],
  }

  // HEVC bit-depth cap when Main 10 isn't supported. Even if Main 8 is,
  // 10-bit sources would otherwise satisfy a Codec match.
  if (hevc8MaxLevel && !hevc10MaxLevel) {
    profile.CodecProfiles.push({
      Type: 'Video',
      Codec: 'hevc,h265',
      Conditions: [
        { Property: 'VideoBitDepth', Condition: 'LessThanEqual', Value: '8', IsRequired: true },
      ],
    })
  }

  // HEVC level cap — pin to the highest level we successfully probed.
  // Without this, the server would direct-play a Level 5.2 file to a
  // decoder that only handles Level 4.0, and the renderer would stall.
  const hevcCap = Math.max(hevc8MaxLevel, hevc10MaxLevel)
  if (hevcCap > 0) {
    profile.CodecProfiles.push({
      Type: 'Video',
      Codec: 'hevc,h265',
      Conditions: [
        { Property: 'VideoLevel', Condition: 'LessThanEqual', Value: String(hevcCap), IsRequired: true },
      ],
    })
  }

  // HDR availability — when the system can't actually display HDR
  // (decodingInfo returns supported:false for PQ+rec2020), force tonemap
  // by blocking HDR direct-play. SDR sources are unaffected.
  if (!hdrSupportedSync()) {
    profile.CodecProfiles.push({
      Type: 'Video',
      Codec: 'hevc,h265,av1,vp9',
      Conditions: [
        { Property: 'VideoRangeType', Condition: 'Equals', Value: 'SDR', IsRequired: true },
      ],
    })
  }

  return profile
}

/**
 * Desktop profile. Picks browser/libmpv variant based on the active
 * playback engine. The libmpv variant advertises broad codec coverage
 * (HEVC HDR, lossless audio, PGS subs) so the server skips transcode
 * for files the engine can decode.
 *
 * @param {Object} [opts]
 * @param {'browser'|'libmpv'} [opts.engine='browser']
 * @param {Object} [opts.capabilities] Decoders+demuxers reported by
 *   libmpv via window.api.getMpvCapabilities(). When omitted, the libmpv
 *   variant falls back to a conservative hardcoded profile so playback
 *   keeps working before the IPC reply arrives.
 */
export function buildDesktopProfile({ engine = 'browser', capabilities } = {}) {
  if (engine === 'libmpv') return buildLibMpvProfile(capabilities)
  return buildBrowserProfile()
}

// ffprobe → Jellyfin rename tables. Copied from JMP's device_profile.cpp.
// Server (server/app/services/device_profile.rb) applies the same maps,
// so the client emitting either side is sufficient.
const CONTAINER_RENAMES = {
  matroska:  'mkv',
  mpegts:    'ts',
  mpegvideo: 'mpeg',
}

const SUBTITLE_RENAMES = {
  subrip:            'srt',
  ass:               'ssa',
  hdmv_pgs_subtitle: 'PGSSUB',
  dvd_subtitle:      'DVDSUB',
  dvb_subtitle:      'DVBSUB',
  dvb_teletext:      'DVBTXT',
}

// Classification for libmpv's decoder-list (a flat list of ffmpeg codec
// names). mpv doesn't tag entries with media kind, so we partition by a
// known-set heuristic. Anything not in these sets is dropped.
const VIDEO_CODECS = new Set([
  'h264', 'hevc', 'h265', 'av1', 'vp9', 'vp8',
  'mpeg4', 'mpeg2video', 'mpeg1video', 'mjpeg', 'h263',
  'theora', 'wmv1', 'wmv2', 'wmv3', 'vc1', 'cavs',
])
const AUDIO_CODECS = new Set([
  'aac', 'ac3', 'eac3', 'mp3', 'mp2', 'flac', 'opus',
  'vorbis', 'truehd', 'dts', 'pcm_s16le', 'pcm_s24le',
  'pcm_s16be', 'pcm_s24be', 'pcm_f32le', 'wmav1', 'wmav2',
  'alac', 'wmapro', 'cook', 'mlp',
])
const SUBTITLE_CODECS = new Set([
  'srt', 'subrip', 'ass', 'ssa', 'webvtt', 'mov_text',
  'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle',
  'pgssub', 'xsub', 'microdvd', 'jacosub', 'sami',
])

function expandWithRenames(names, renames) {
  const seen = new Set()
  const out = []
  for (const name of names) {
    if (!name) continue
    if (!seen.has(name)) { seen.add(name); out.push(name) }
    const renamed = renames[name]
    if (renamed && !seen.has(renamed)) { seen.add(renamed); out.push(renamed) }
  }
  return out
}

function buildLibMpvProfile(capabilities) {
  // Conservative fallback when capabilities haven't loaded yet — kicks
  // in for the first session opened before window.api.getMpvCapabilities()
  // resolves. Mirrors the codec floor of a build-libmpv produced bundle.
  if (!capabilities) {
    return {
      Name: 'caramba-desktop-libmpv-fallback',
      MaxStaticBitrate: 1_000_000_000,
      DirectPlayProfiles: [
        { Container: 'mkv,mp4,m4v,mov,webm,avi,ts,m2ts,matroska',
          Type: 'Video',
          VideoCodec: 'h264,hevc,h265,av1,vp9,vp8,mpeg4,mpeg2video',
          AudioCodec: 'aac,ac3,eac3,flac,mp3,opus,truehd,dts,vorbis,pcm_s16le,pcm_s24le' },
        { Container: 'mp4,m4v,mp3,flac,ogg,m4a',
          Type: 'Audio',
          AudioCodec: 'aac,ac3,eac3,flac,mp3,opus' },
      ],
      TranscodingProfiles: [
        { Container: TRANSCODE_TARGET_CONTAINER, Type: 'Video', Protocol: 'hls',
          VideoCodec: TRANSCODE_TARGET_VIDEO, AudioCodec: 'aac,ac3,eac3',
          MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS },
      ],
      SubtitleProfiles: [
        { Format: 'srt', Method: 'External' },
        { Format: 'subrip', Method: 'External' },
        { Format: 'ssa', Method: 'External' },
        { Format: 'ass', Method: 'External' },
        { Format: 'vtt', Method: 'External' },
        { Format: 'PGSSUB', Method: 'Embed' },
        { Format: 'hdmv_pgs_subtitle', Method: 'Embed' },
        { Format: 'DVDSUB', Method: 'Embed' },
        { Format: 'dvd_subtitle', Method: 'Embed' },
      ],
      CodecProfiles: [],
      ContainerProfiles: [],
    }
  }

  // Classify mpv's flat decoder list into video/audio by name. mpv's
  // `decoder-list` property only enumerates video/audio decoders —
  // subtitle support is built into mpv (libass for ASS/SSA, internal
  // renderer for SRT/VTT/PGS/DVD bitmaps) and isn't surfaced through
  // decoder-list, so we hardcode the canonical set below instead of
  // filtering it out and ending up with empty SubtitleProfiles.
  const decoders = capabilities.decoders || []
  const videoDecoders = decoders.filter(c => VIDEO_CODECS.has(c))
  const audioDecoders = decoders.filter(c => AUDIO_CODECS.has(c))

  // Demuxer list: ffmpeg's lavf names with the raw + renamed form so
  // the server matches either.
  const containers = expandWithRenames(capabilities.demuxers || [], CONTAINER_RENAMES)

  const profile = {
    Name: 'caramba-desktop-libmpv',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [],
    TranscodingProfiles: [
      { Container: TRANSCODE_TARGET_CONTAINER, Type: 'Video', Protocol: 'hls',
        VideoCodec: TRANSCODE_TARGET_VIDEO, AudioCodec: 'aac,ac3,eac3',
        MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS },
    ],
    SubtitleProfiles: [],
    CodecProfiles: [],
    ContainerProfiles: [],
  }

  if (videoDecoders.length > 0) {
    profile.DirectPlayProfiles.push({
      Container: containers.join(','),
      Type: 'Video',
      VideoCodec: videoDecoders.join(','),
      AudioCodec: audioDecoders.join(','),
    })
  }
  if (audioDecoders.length > 0) {
    profile.DirectPlayProfiles.push({
      Container: containers.join(','),
      Type: 'Audio',
      AudioCodec: audioDecoders.join(','),
    })
  }

  // Subtitle formats mpv handles natively, listed under both their raw
  // ffprobe codec name and the canonical Jellyfin rename so the server
  // matches either side without further translation. Method=Embed for
  // muxed streams (mpv reads them directly from the source container);
  // also External so VTT/SRT sidecars work too.
  const MPV_NATIVE_SUBTITLE_FORMATS = [
    'srt', 'subrip',                      // SubRip text
    'ass', 'ssa',                         // Advanced SubStation Alpha (libass)
    'webvtt', 'vtt',                      // WebVTT
    'mov_text',                           // MP4 timed-text
    'pgssub', 'hdmv_pgs_subtitle', 'PGSSUB',  // Blu-ray PGS bitmap
    'dvd_subtitle', 'DVDSUB',             // DVD VobSub bitmap
    'dvb_subtitle', 'DVBSUB',             // DVB bitmap
  ]
  for (const fmt of MPV_NATIVE_SUBTITLE_FORMATS) {
    profile.SubtitleProfiles.push({ Format: fmt, Method: 'Embed' })
    profile.SubtitleProfiles.push({ Format: fmt, Method: 'External' })
  }

  return profile
}

/**
 * Android TV profile. ExoPlayer (Media3) reads MKV via MatroskaExtractor;
 * decodes HEVC HDR + AC-3/E-AC-3/TrueHD/DTS audio + PGS bitmap subs
 * directly. Hardcoded — ExoPlayer's capabilities don't surface via MSE.
 */
export function buildAndroidTvProfile() {
  return {
    Name: 'caramba-android-tv',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [
      { Container: 'mkv,webm,mp4,m4v,mov,ts,m2ts,avi',
        Type: 'Video',
        VideoCodec: 'h264,hevc,h265,vp9,av1,mpeg4,mpeg2video',
        AudioCodec: 'aac,ac3,eac3,flac,mp3,opus,truehd,dts,dtshd,vorbis,pcm_s16le,pcm_s24le' },
      { Container: 'mp4,m4v,mp3,flac,ogg,m4a',
        Type: 'Audio',
        AudioCodec: 'aac,ac3,eac3,flac,mp3,opus' },
    ],
    TranscodingProfiles: [
      { Container: TRANSCODE_TARGET_CONTAINER, Type: 'Video', Protocol: 'hls',
        VideoCodec: TRANSCODE_TARGET_VIDEO, AudioCodec: 'aac,ac3,eac3',
        MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS },
    ],
    SubtitleProfiles: [
      { Format: 'srt', Method: 'External' },
      { Format: 'subrip', Method: 'External' },
      { Format: 'ssa', Method: 'External' },
      { Format: 'ass', Method: 'External' },
      { Format: 'vtt', Method: 'External' },
      { Format: 'PGSSUB', Method: 'Embed' },
      { Format: 'hdmv_pgs_subtitle', Method: 'Embed' },
    ],
    CodecProfiles: [],
    ContainerProfiles: [],
  }
}
