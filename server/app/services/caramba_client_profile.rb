# Translates the JSON DeviceProfile that web/desktop/android-tv clients send
# in `POST /api/playback/start` into a Jellyfin::Playback::ClientProfile that
# the engine's Decision module consumes.
#
# The JSON shape (DirectPlayProfiles + TranscodingProfiles + CodecProfiles +
# SubtitleProfiles + MaxStaticBitrate) mirrors Jellyfin's DLNA profile schema,
# so the field-to-field mapping is mechanical. We extract the union of codecs
# across DirectPlayProfiles entries, then walk CodecProfiles for the per-codec
# constraints the engine actually reads: bit-depth, level, framerate, HDR.

class CarambaClientProfile
  CSV_RE = /\s*,\s*/

  class << self
    def build(device_profile)
      device_profile = (device_profile || {}).deep_stringify_keys
      profile = Jellyfin::Playback::ClientProfile.modern_browser

      # Default to 10-bit-capable. Clients that genuinely can't decode
      # 10-bit (e.g. Electron 33 / Chromium 130 MSE) emit a
      # `VideoBitDepth <= 8` CodecProfile condition in their
      # DeviceProfile — `apply_codec_constraints!` flips this back to
      # false for those clients. Mirrors upstream Jellyfin's
      # `browserDeviceProfile` 10-bit eligibility logic, and unblocks
      # the `:direct_stream` (HEVC fMP4 stream-copy) path that Safari
      # needs to start playback in <1 s on the user's HEVC rips.
      #
      # The companion fix is the variant playlist: ffmpeg's HLS muxer
      # cuts stream-copy segments on source keyframes, producing variable
      # durations (9.1s, 4.0s, 8.7s, ...). The engine now reads MKV Cues
      # via `Jellyfin::Keyframes::Extractor` and builds the playlist with
      # those real keyframe intervals, mirroring upstream
      # `DynamicHlsPlaylistGenerator.ComputeSegments`. Without that the
      # playlist's `#EXTINF` values disagreed with segment PTS and
      # Safari rejected with MEDIA_ERR_DECODE.
      profile.supports_10bit = true

      direct_play = Array(device_profile["DirectPlayProfiles"])
      transcoding = Array(device_profile["TranscodingProfiles"])
      codec_profiles = Array(device_profile["CodecProfiles"])

      apply_direct_play!(profile, direct_play)
      apply_transcoding!(profile, transcoding)
      apply_codec_constraints!(profile, codec_profiles)
      apply_bitrate_cap!(profile, device_profile)

      profile
    end

    private

    def apply_direct_play!(profile, entries)
      containers = Set.new
      video_codecs = Set.new
      audio_codecs = Set.new

      entries.each do |entry|
        split_csv(entry["Container"]).each { |c| containers << c.downcase }
        split_csv(entry["VideoCodec"]).each { |c| video_codecs << c.downcase }
        split_csv(entry["AudioCodec"]).each { |c| audio_codecs << c.downcase }
      end

      profile.containers   = containers.to_a   if containers.any?
      profile.video_codecs = video_codecs.to_a if video_codecs.any?
      profile.audio_codecs = audio_codecs.to_a if audio_codecs.any?
    end

    def apply_transcoding!(profile, entries)
      # We only need transcoding profiles to enrich the codec lists. The
      # engine picks the actual transcode target itself based on what's
      # available client-side; the union is enough for Decision lookups.
      audio_union = Set.new(profile.audio_codecs)
      entries.each do |entry|
        split_csv(entry["AudioCodec"]).each { |c| audio_union << c.downcase }
      end
      profile.audio_codecs = audio_union.to_a if audio_union.any?
    end

    def apply_codec_constraints!(profile, codec_profiles)
      codec_profiles.each do |cp|
        # `Video`, `VideoAudio` (audio in video container), and `Audio`
        # all carry conditions our profile cares about. Mirrors upstream's
        # CodecProfile.Type enum — the matchers below decide which fields
        # to update per condition Property.
        type = cp["Type"].to_s.downcase
        next unless %w[video videoaudio audio].include?(type)
        codecs = split_csv(cp["Codec"]).map(&:downcase)
        Array(cp["Conditions"]).each do |cond|
          apply_condition!(profile, codecs, cond)
        end
      end
    end

    def apply_condition!(profile, codecs, cond)
      property = cond["Property"].to_s
      op       = cond["Condition"].to_s
      value    = cond["Value"].to_s

      case property
      when "VideoBitDepth"
        if op == "LessThanEqual" && value == "8"
          profile.supports_10bit = false
        end
      when "VideoLevel"
        level = value.to_i
        if codecs.include?("hevc") || codecs.include?("h265")
          profile.hevc_level = level if profile.hevc_level.nil? || level < profile.hevc_level
        end
        if codecs.include?("h264")
          profile.h264_level = level if profile.h264_level.nil? || level < profile.h264_level
        end
      when "VideoFramerate"
        if op == "LessThanEqual"
          fps = value.to_f
          profile.max_video_fps = fps if profile.max_video_fps.nil? || fps < profile.max_video_fps
        end
      when "VideoRangeType"
        # Upstream uses `EqualsAny` with a `|`-separated value list to
        # declare HDR/HLG/Dolby Vision support — Jellyfin's androidtv,
        # appletv, and tizen profiles all advertise like this. Without
        # this branch, the AndroidTV / Chromecast profile had no path to
        # turn `supports_hdr` ON, so every HDR10 source fell through to
        # full_transcode + tonemap even though the hardware decoder can
        # render HDR10 natively. Mirrors
        # Jellyfin.Server.Implementations.Library.DeviceProfile parsing
        # of ConditionType.EqualsAny on VideoRangeType.
        if op == "Equals" && value.casecmp?("SDR")
          profile.supports_hdr = false
          profile.supports_dovi = false
        elsif op == "EqualsAny"
          values = value.split("|").map(&:upcase)
          profile.supports_hdr  = values.any? { |v| %w[HDR10 HLG DOVI].include?(v) }
          profile.supports_dovi = values.include?("DOVI")
        end
      when "Height"
        # Always override: the client's declared cap is authoritative.
        # Previously this only tightened the cap, so the
        # `modern_browser` default of 1080 silently blocked AndroidTV /
        # Chromecast (4K-capable HW) from direct_play on 2160p sources
        # even when the device profile declared Height <= 2160.
        profile.max_video_height = value.to_i if op == "LessThanEqual"
      when "Width"
        profile.max_video_width  = value.to_i if op == "LessThanEqual"
      when "AudioChannels"
        # Lets AndroidTV / Chromecast declare 8ch passthrough so 7.1
        # TrueHD/DTS-HD MA sources direct-play instead of being audio-
        # transcoded down to 6ch (which on these clients also drags
        # video into a full_transcode for the muxer to stay coherent).
        # ExoPlayer's AudioCapabilities auto-downmixes when the actual
        # output sink is stereo, so declaring 8 doesn't break low-channel
        # devices.
        profile.max_audio_channels = value.to_i if op == "LessThanEqual"
      end
    end

    def apply_bitrate_cap!(profile, device_profile)
      cap = device_profile["MaxStreamingBitrate"] || device_profile["MaxStaticBitrate"]
      profile.max_video_bitrate = cap.to_i if cap
    end

    def split_csv(value)
      value.to_s.split(CSV_RE).reject(&:blank?)
    end
  end
end
