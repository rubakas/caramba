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

// Native HLS probe — used to detect what Safari (and Safari-flavoured
// engines like Playwright webkit) can decode via the <video src=.m3u8>
// path. Mirrors jellyfin-web's `canPlayNativeHls` + the `application/
// x-mpegurl` codec tests in `browserDeviceProfile.js:80, 149-151`.
// Without this, Safari's DeviceProfile only carries MSE-probed codecs
// — which on Safari is a strict subset of what the browser actually
// plays — and the server transcodes everything Safari could otherwise
// stream-copy.
function _videoTestElement() {
  if (typeof document === 'undefined') return null
  return document.createElement('video')
}

function nativeHlsSupported() {
  const v = _videoTestElement()
  if (!v || typeof v.canPlayType !== 'function') return false
  return !!(v.canPlayType('application/x-mpegurl').replace(/no/, '') ||
            v.canPlayType('application/vnd.apple.mpegURL').replace(/no/, ''))
}

// Probe whether the native HLS engine can play a given codec string.
// `codecs` is the value that goes inside the MIME type's `codecs="..."`.
function nativeHlsCanPlay(codecs) {
  const v = _videoTestElement()
  if (!v || typeof v.canPlayType !== 'function') return false
  return !!(v.canPlayType(`application/x-mpegurl; codecs="${codecs}"`).replace(/no/, '') ||
            v.canPlayType(`application/vnd.apple.mpegURL; codecs="${codecs}"`).replace(/no/, ''))
}

// Direct (non-HLS) container probe via canPlayType. Distinct from MSE:
// Safari's native demuxer for MP4/MOV accepts a broader codec set than
// its MSE SourceBuffer.
function canPlayMp4(codecs) {
  const v = _videoTestElement()
  if (!v || typeof v.canPlayType !== 'function') return false
  return !!v.canPlayType(`video/mp4; codecs="${codecs}"`).replace(/no/, '')
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

// Smoothness probe — mediaCapabilities.decodingInfo returns
// `{ supported, smooth, powerEfficient }`. `supported:true && smooth:false`
// means "the decoder will accept the bitstream but can't keep up at this
// framerate / bitrate combination on this device" (e.g. some 4K60 HEVC
// playback judders on integrated GPUs). Jellyfin uses this signal to
// emit per-codec framerate / bitrate caps rather than letting playback
// silently stutter.
//
// We probe two combinations per codec: 4K30 (baseline) and 4K60 (the
// usual smoothness break point). If 4K60 isn't smooth but 4K30 is,
// emit VideoFramerate <= 30 for that codec.
async function probeSmoothness({ codec, framerate, width = 3840, height = 2160, bitrate = 20_000_000 }) {
  if (typeof navigator === 'undefined' || !navigator.mediaCapabilities?.decodingInfo) return null
  try {
    const info = await navigator.mediaCapabilities.decodingInfo({
      type: 'media-source',
      video: { contentType: codec, width, height, bitrate, framerate },
    })
    return { supported: !!info.supported, smooth: !!info.smooth, powerEfficient: !!info.powerEfficient }
  } catch { return null }
}

const _smoothCache = {}
let _smoothProbeStarted = false
function smoothMaxFramerate(codecKey, contentType) {
  // Returns 60, 30, or null:
  //   60  → 4K60 probe succeeded and was smooth (no cap needed)
  //   30  → 4K60 supported but not smooth; cap to 30fps
  //   null → 4K60 probe failed (omit cap; let isTypeSupported govern)
  if (codecKey in _smoothCache) return _smoothCache[codecKey]
  if (!_smoothProbeStarted) {
    _smoothProbeStarted = true
    ;(async () => {
      const at60 = await probeSmoothness({ codec: contentType, framerate: 60 })
      if (!at60 || !at60.supported) { _smoothCache[codecKey] = null; return }
      _smoothCache[codecKey] = at60.smooth ? 60 : 30
    })()
  }
  return null
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

  // Native HLS extension. On Safari (and any browser that reports
  // canPlayType('application/vnd.apple.mpegURL')), HEVC + AC-3 + E-AC-3
  // + DTS are decodable via the native HLS engine even though MSE
  // isTypeSupported() returns "" for them. Adding these to the codec
  // lists flips the server's strategy from `full_transcode` to
  // `direct_stream` (container remux only) for HEVC+AC3 sources —
  // matches what jellyfin-web does in `browserDeviceProfile.js` lines
  // 80, 149-160 (canPlayNativeHls + supportsAc3InHls + supportsMp3InHls
  // + the HEVC code path on iOS/macOS).
  if (nativeHlsSupported()) {
    // HEVC via native HLS — Safari accepts both hvc1 / hev1 fourcc.
    // jellyfin-web's canPlayHevc (browserDeviceProfile.js:9-23) probes
    // the bare "hvc1.1.L120" / "hev1.1.L120" forms (Main profile, level
    // 4.0, no compatibility flag, no constraint flag). Safari returns
    // empty for the more specific "hvc1.1.6.L120" form even though it
    // decodes the bitstream — so the .6. variant gave a false negative,
    // left 'hevc' out of videoCodecs, and made the server pick
    // full_transcode for HEVC sources (vs audio_transcode in Chrome).
    const hevcNative =
      canPlayMp4('hvc1.1.L120') ||
      canPlayMp4('hev1.1.L120') ||
      canPlayMp4('hvc1.1.0.L120') ||
      canPlayMp4('hev1.1.0.L120') ||
      nativeHlsCanPlay('hvc1.1.L120') ||
      nativeHlsCanPlay('hev1.1.L120')
    if (hevcNative && !videoCodecs.includes('hevc')) videoCodecs.push('hevc', 'h265')

    // AC-3 / E-AC-3 via native HLS. The probe codec strings come from
    // jellyfin-web — they use a paired AVC+AC3 string because the HLS
    // mime type expects both video and audio codecs together.
    const ac3Native =
      nativeHlsCanPlay('avc1.42E01E, ac-3') ||
      canPlayMp4('ac-3')
    if (ac3Native && !audioCodecs.includes('ac3')) audioCodecs.push('ac3')

    const eac3Native =
      nativeHlsCanPlay('avc1.42E01E, ec-3') ||
      canPlayMp4('ec-3')
    if (eac3Native && !audioCodecs.includes('eac3')) audioCodecs.push('eac3')

    // DTS / DTS-HD on macOS Safari (when AppleTV's audio extension is
    // present). Conservative — match jellyfin-web's two-form probe.
    const dtsNative =
      canPlayMp4('dts-') ||
      canPlayMp4('dts+') ||
      canPlayMp4('dts')
    if (dtsNative && !audioCodecs.includes('dts')) audioCodecs.push('dts')
  }

  // Containers MSE / <video> can demux directly. mp4 family only — MKV,
  // AVI, TS, WebM require remuxing on the server (direct_stream).
  const directPlayContainer = 'mp4,m4v,mov,mj2'

  // Two TranscodingProfiles per Jellyfin's pattern. Server picks
  // segment container per source codec:
  //   { Container: 'ts',  VideoCodec: 'h264' }            - mpegts
  //   { Container: 'mp4', VideoCodec: 'h264,hevc,av1' }   - fmp4
  // Anything in the mp4-but-not-ts set (HEVC, AV1, FLAC, Opus) ends up
  // in fmp4 segments which Safari can decode; H.264 stays in mpegts
  // (smaller per-segment overhead, no init segment needed).
  // Mirrors jellyfin-web's browserDeviceProfile.js:850-947 where
  // hlsInTsVideoCodecs and hlsInFmp4VideoCodecs feed separate
  // TranscodingProfiles.
  const hlsTsVideoCodecs = [ 'h264' ]
  const hlsTsAudioCodecs = audioCodecs.filter(c => [ 'aac', 'ac3', 'eac3', 'mp3' ].includes(c))

  const hlsFmp4VideoCodecs = [ 'h264' ]
  if (hevc8MaxLevel || hevc10MaxLevel) hlsFmp4VideoCodecs.push('hevc', 'h265')
  if (av1 || av1Hdr) hlsFmp4VideoCodecs.push('av1')
  const hlsFmp4AudioCodecs = audioCodecs.filter(c =>
    [ 'aac', 'ac3', 'eac3', 'mp3', 'flac', 'opus' ].includes(c))

  // Order matches jellyfin-web's `browserDeviceProfile.js`:910-944 —
  // fMP4 first, MPEG-TS second. The server picks the first matching
  // TranscodingProfile, so listing fMP4 first makes HEVC sources (and
  // every transcode that the fMP4 profile accepts) go through fMP4
  // segments. Safari plays fMP4 segments natively and Jellyfin's
  // browser client uses this exact same ordering.
  const transcodingProfiles = []
  if (hlsFmp4VideoCodecs.length > 1) {
    transcodingProfiles.push({
      Container: 'mp4', Type: 'Video', Protocol: 'hls',
      VideoCodec: hlsFmp4VideoCodecs.join(','),
      AudioCodec: hlsFmp4AudioCodecs.join(','),
      MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS,
    })
  }
  transcodingProfiles.push({
    Container: 'ts', Type: 'Video', Protocol: 'hls',
    VideoCodec: hlsTsVideoCodecs.join(','),
    AudioCodec: hlsTsAudioCodecs.join(','),
    MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS,
  })

  const profile = {
    Name: 'caramba-browser',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [
      { Container: directPlayContainer, Type: 'Video',
        VideoCodec: videoCodecs.join(','), AudioCodec: audioCodecs.join(',') },
      { Container: directPlayContainer, Type: 'Audio',
        AudioCodec: audioCodecs.join(',') },
    ],
    TranscodingProfiles: transcodingProfiles,
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

  // Smoothness caps via mediaCapabilities.decodingInfo. When the
  // browser reports decoder "supported" but not "smooth" at 4K60 for
  // HEVC or AV1, emit VideoFramerate <= 30 so the server transcodes
  // high-fps 4K sources rather than letting playback stutter.
  if (hevcCap > 0) {
    const cap = smoothMaxFramerate('hevc-4k', `video/mp4; codecs="hvc1.1.6.L${hevcCap}.B0"`)
    if (cap === 30) {
      profile.CodecProfiles.push({
        Type: 'Video',
        Codec: 'hevc,h265',
        Conditions: [
          { Property: 'VideoFramerate', Condition: 'LessThanEqual', Value: '30', IsRequired: false },
        ],
      })
    }
  }
  if (av1 || av1Hdr) {
    const cap = smoothMaxFramerate('av1-4k', 'video/mp4; codecs="av01.0.05M.08"')
    if (cap === 30) {
      profile.CodecProfiles.push({
        Type: 'Video',
        Codec: 'av1',
        Conditions: [
          { Property: 'VideoFramerate', Condition: 'LessThanEqual', Value: '30', IsRequired: false },
        ],
      })
    }
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
 * Desktop profile. The desktop renderer is Chromium; the Jellyfin Player JS
 * runtime drives the same `<video>` + hls.js / Safari native HLS pipeline
 * the browser uses, so we just delegate to the browser profile builder.
 */
export function buildDesktopProfile() {
  return buildBrowserProfile()
}

/**
 * Android TV profile. ExoPlayer (Media3) reads MKV via MatroskaExtractor;
 * decodes HEVC HDR (incl. Dolby Vision profile 5/7/8) + AC-3/E-AC-3/
 * TrueHD/DTS/DTS-HD audio + PGS bitmap subs directly. Hardcoded —
 * ExoPlayer's capabilities don't surface via MSE in the WebView.
 *
 * Coverage mirrors jellyfin-androidtv's DeviceProfileBuilder: codec and
 * container lists, plus per-codec HDR conditions matching what
 * ExoPlayer's renderers handle natively on Android TV hardware.
 */
// Default audio codec list — used when AudioCapabilities probe hasn't run
// (or failed). Mirrors the historical static list. The probe-driven path
// (passing `audioCaps`) overrides this with what the device's HDMI/decoder
// pipeline ACTUALLY supports.
const ANDROID_TV_DEFAULT_AUDIO_CODECS =
  'aac,ac3,eac3,flac,mp3,opus,truehd,dts,dtshd,mlp,vorbis,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be,pcm_f32le'

function androidTvAudioCodecList(audioCaps) {
  const probed = audioCaps?.supportedEncodings
  if (!Array.isArray(probed) || probed.length === 0) return ANDROID_TV_DEFAULT_AUDIO_CODECS
  // Deduplicate, lowercase, preserve a stable order roughly matching the
  // historical list so server-side audio-codec preference ordering doesn't
  // change for codecs that ARE supported.
  const order = [
    'aac', 'ac3', 'eac3', 'eac3_joc', 'flac', 'mp3', 'opus',
    'truehd', 'dts', 'dtshd', 'mlp', 'vorbis',
    'pcm_s16le', 'pcm_s24le', 'pcm_s16be', 'pcm_s24be', 'pcm_f32le',
  ]
  const supported = new Set(probed.map(c => String(c).toLowerCase()))
  return order.filter(c => supported.has(c)).join(',') || ANDROID_TV_DEFAULT_AUDIO_CODECS
}

export function buildAndroidTvProfile({ audioCaps } = {}) {
  const audioCodecs = androidTvAudioCodecList(audioCaps)
  const maxChannels = Math.max(2, Number(audioCaps?.maxChannelCount) || 8)
  return {
    Name: 'caramba-android-tv',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [
      // Expanded container coverage to match Jellyfin AndroidTV's
      // matroska/mpegts/avi/asf/vob extractors. nut is rare but
      // supported via the generic FFmpegExtractor.
      { Container: 'mkv,webm,mp4,m4v,mov,ts,m2ts,avi,asf,vob,nut,3gp,3g2',
        Type: 'Video',
        // h265 alias for hevc; vc1 widely supported on Android TV
        // chipsets; mpeg/mpeg1video for legacy content.
        VideoCodec: 'h264,hevc,h265,vp8,vp9,av1,mpeg4,mpeg2video,mpeg1video,mpeg,vc1',
        // Audio codec list is built from Media3's AudioCapabilities probe
        // (passed in from AppAndroid.jsx). On a Chromecast → TV without an
        // AVR this drops DTS/TrueHD entirely; on a setup with an AVR that
        // advertises DTS/TrueHD in EDID those stay in. The previous static
        // list lied about DTS and the chip silently fell back to whatever
        // backup audio the file had (e.g. AC3 commentary instead of DTS
        // main).
        AudioCodec: audioCodecs },
      { Container: 'mp4,m4v,mp3,flac,ogg,m4a,aac,wav',
        Type: 'Audio',
        AudioCodec: 'aac,ac3,eac3,flac,mp3,opus,vorbis' },
    ],
    TranscodingProfiles: [
      { Container: TRANSCODE_TARGET_CONTAINER, Type: 'Video', Protocol: 'hls',
        VideoCodec: TRANSCODE_TARGET_VIDEO, AudioCodec: 'aac,ac3,eac3',
        MaxAudioChannels: TRANSCODE_TARGET_MAX_AUDIO_CHANNELS },
    ],
    SubtitleProfiles: [
      // Text — ExoPlayer renders these via its built-in TextRenderer
      // (libass-style typography lost; for that, ASS would need
      // dedicated client-side rendering as discussed in Part 1 F).
      { Format: 'srt',     Method: 'External' },
      { Format: 'subrip',  Method: 'External' },
      { Format: 'ssa',     Method: 'External' },
      { Format: 'ass',     Method: 'External' },
      { Format: 'vtt',     Method: 'External' },
      { Format: 'webvtt',  Method: 'External' },
      { Format: 'mov_text',Method: 'Embed'    },
      // Bitmap — PGS/DVD/DVB rendered by Media3's PGS / DVB renderers
      // (DVD VobSub support landed in Media3 1.4 / ExoPlayer 2.19).
      { Format: 'PGSSUB',  Method: 'Embed' },
      { Format: 'hdmv_pgs_subtitle', Method: 'Embed' },
      { Format: 'DVDSUB',  Method: 'Embed' },
      { Format: 'dvd_subtitle', Method: 'Embed' },
      { Format: 'DVBSUB',  Method: 'Embed' },
      { Format: 'dvb_subtitle', Method: 'Embed' },
    ],
    CodecProfiles: [
      // HEVC: level cap + HDR10/HLG support declared so the server doesn't
      // force-transcode HDR sources for tonemapping. Chromecast with Google
      // TV and modern AndroidTV chipsets decode HEVC Main 10 HDR10 / HLG in
      // hardware — no need to remap. Mirrors the upstream Jellyfin
      // androidtv DeviceProfile pattern (EqualsAny on VideoRangeType).
      // Level 153 == HEVC level_idc 5.1 (4K60 10-bit HDR), above which the
      // chipset can't decode in hardware.
      // Height/Width 2160/3840 raise the default 1080p cap inherited from
      // the engine's modern_browser baseline — required for 4K direct play.
      {
        Type: 'Video',
        Codec: 'hevc,h265',
        Conditions: [
          { Property: 'VideoLevel', Condition: 'LessThanEqual', Value: '153', IsRequired: false },
          { Property: 'VideoRangeType', Condition: 'EqualsAny', Value: 'SDR|HDR10|HLG', IsRequired: false },
          { Property: 'Height', Condition: 'LessThanEqual', Value: '2160', IsRequired: false },
          { Property: 'Width',  Condition: 'LessThanEqual', Value: '3840', IsRequired: false },
        ],
      },
      // H.264 level cap — Level 5.2 (51) covers 4K30 / 1080p120, beyond
      // what most ATV chipsets handle in hardware.
      {
        Type: 'Video',
        Codec: 'h264',
        Conditions: [
          { Property: 'VideoLevel', Condition: 'LessThanEqual', Value: '51', IsRequired: false },
          { Property: 'Height', Condition: 'LessThanEqual', Value: '2160', IsRequired: false },
          { Property: 'Width',  Condition: 'LessThanEqual', Value: '3840', IsRequired: false },
        ],
      },
      // Max audio channels — set from Media3's AudioCapabilities probe so a
      // Chromecast → stereo TV reports 2, a Chromecast → 5.1 AVR reports 6,
      // and a 7.1 AVR reports 8. Without the probe we lied with 8 by
      // default, which forced ExoPlayer's AudioSink to downmix in a path
      // that occasionally tripped track-selection edge cases.
      {
        Type: 'VideoAudio',
        Conditions: [
          { Property: 'AudioChannels', Condition: 'LessThanEqual', Value: String(maxChannels), IsRequired: false },
        ],
      },
    ],
    ContainerProfiles: [],
  }
}
