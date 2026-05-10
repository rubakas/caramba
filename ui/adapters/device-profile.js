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
 * Desktop profile. Picks browser/libvlc/libmpv variant based on the active
 * playback engine. The libvlc/libmpv variants advertise broader codec
 * coverage so the server skips transcode for files the engine can decode.
 *
 * @param {Object} [opts]
 * @param {'browser'|'libvlc'|'libmpv'} [opts.engine='browser']
 */
export function buildDesktopProfile({ engine = 'browser' } = {}) {
  if (engine === 'libvlc') return buildLibVlcProfile()
  if (engine === 'libmpv') return buildLibMpvProfile()
  return buildBrowserProfile()
}

function buildLibVlcProfile() {
  // Conservative profile reflecting libVLC's coverage in Caramba. libVLC
  // decodes a wide range of codecs; we list the common ones and lean on
  // the server's transcode for everything else.
  return {
    Name: 'caramba-desktop-libvlc',
    MaxStaticBitrate: 1_000_000_000,
    DirectPlayProfiles: [
      { Container: 'mkv,mp4,m4v,mov,webm,avi,ts,m2ts',
        Type: 'Video',
        VideoCodec: 'h264,hevc,h265,vp9,av1,mpeg4,mpeg2video',
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

function buildLibMpvProfile() {
  // Placeholder until Deliverable B (libVLC → libmpv swap) lands. Will be
  // generated from mpv_get_property("decoder-list" / "demuxer-lavf-list").
  // Today returns the libVLC profile so the engine stays operational.
  return buildLibVlcProfile()
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
