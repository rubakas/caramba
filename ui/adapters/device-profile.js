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
  const hevc8 = probe('video/mp4; codecs="hvc1.1.6.L120.B0"') || probe('video/mp4; codecs="hev1.1.6.L120.B0"')
  // Electron 33 / Chromium 130 MSE accepts the codec string but stalls on
  // 10-bit playback (segments arrive, decoder produces no frames). Real
  // browsers (Safari, Chrome 107+) decode 10-bit HEVC reliably.
  const hevc10 = !isElectronRuntime() && (
    probe('video/mp4; codecs="hvc1.2.4.L150.B0"') ||
    probe('video/mp4; codecs="hev1.2.4.L150.B0"')
  )

  const audioFlags = {
    aac:  true, // unconditional — every MSE-capable browser supports it
    ac3:  probe('audio/mp4; codecs="ac-3"'),
    eac3: probe('audio/mp4; codecs="ec-3"'),
    flac: probe('audio/mp4; codecs="flac"'),
    mp3:  probe('audio/mp4; codecs="mp4a.40.34"') || probe('audio/mp4; codecs="mp3"'),
    opus: probe('audio/mp4; codecs="opus"'),
  }

  const videoCodecs = []
  if (h264)  videoCodecs.push('h264')
  if (hevc8) videoCodecs.push('hevc', 'h265')

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
      // Browsers render WebVTT via <track>. Server extracts to VTT and
      // serves at /api/playback/subtitles?session=...
      { Format: 'vtt', Method: 'External' },
    ],
    CodecProfiles: [],
    ContainerProfiles: [],
  }

  // HEVC Main 10 unsupported — cap HEVC bit depth at 8 so the server
  // transcodes 10-bit/HDR sources instead of attempting direct-stream.
  if (hevc8 && !hevc10) {
    profile.CodecProfiles.push({
      Type: 'Video',
      Codec: 'hevc,h265',
      Conditions: [
        { Property: 'VideoBitDepth', Condition: 'LessThanEqual', Value: '8', IsRequired: true },
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

  // Classify mpv's flat decoder list into video/audio/subtitle by name.
  const decoders = capabilities.decoders || []
  const videoDecoders = decoders.filter(c => VIDEO_CODECS.has(c))
  const audioDecoders = decoders.filter(c => AUDIO_CODECS.has(c))
  const subDecoders = decoders.filter(c => SUBTITLE_CODECS.has(c))

  // Demuxer list: ffmpeg's lavf names with the raw + renamed form so
  // the server matches either.
  const containers = expandWithRenames(capabilities.demuxers || [], CONTAINER_RENAMES)
  const subFormats = expandWithRenames(subDecoders, SUBTITLE_RENAMES)

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

  for (const fmt of subFormats) {
    // mpv renders both embed and external subtitle streams natively
    // (libass for ASS/SSA, native PGS bitmap overlay). Server can serve
    // either form.
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
