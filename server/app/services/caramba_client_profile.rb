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
        next unless cp["Type"].to_s.downcase == "video"
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
        if op == "Equals" && value.casecmp?("SDR")
          profile.supports_hdr = false
          profile.supports_dovi = false
        end
      when "Height"
        if op == "LessThanEqual"
          h = value.to_i
          profile.max_video_height = h if profile.max_video_height.nil? || h < profile.max_video_height
        end
      when "Width"
        if op == "LessThanEqual"
          w = value.to_i
          profile.max_video_width = w if profile.max_video_width.nil? || w < profile.max_video_width
        end
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
