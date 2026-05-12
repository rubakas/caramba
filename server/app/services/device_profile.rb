# DeviceProfile — server-side evaluator for the Jellyfin-style profile each
# client sends with POST /api/playback/start.
#
# The profile declares what the client can decode directly (DirectPlayProfiles),
# what the server may transcode TO (TranscodingProfiles), which subtitle
# formats it can render and how (SubtitleProfiles), and any per-codec
# constraints (CodecProfiles, e.g. "HEVC up to 8-bit only").
#
# Decision flow used by TranscoderService.transcode_strategy:
#   1. direct_play_match?    — file matches a DirectPlayProfile + CodecProfiles
#   2. video/audio_supported — used to fall back to direct_stream / audio_transcode
#   3. transcode_target      — chosen TranscodingProfile output codecs/container
#   4. subtitle_method_for   — Embed / External / nil (=> burn-in needed)
#
# Schema reference: jellyfin-desktop/src/jellyfin/device_profile.cpp.
class DeviceProfile
  # ffprobe pix_fmt values that indicate >8-bit video.
  TEN_BIT_PIX_FMTS = %w[
    yuv420p10le yuv420p10be
    yuv422p10le yuv422p10be
    yuv444p10le yuv444p10be
    p010le p010be
  ].freeze

  # ffprobe → Jellyfin rename table, mirrors device_profile.cpp:32-45. Lets
  # the server match either form so client profiles can list the canonical
  # Jellyfin name (PGSSUB, srt, mkv) without the server having to know the
  # ffprobe original.
  SUBTITLE_RENAMES = {
    "subrip"            => "srt",
    "ass"               => "ssa",
    "hdmv_pgs_subtitle" => "PGSSUB",
    "dvd_subtitle"      => "DVDSUB",
    "dvb_subtitle"      => "DVBSUB",
    "dvb_teletext"      => "DVBTXT"
  }.freeze

  CONTAINER_RENAMES = {
    "matroska"  => "mkv",
    "mpegts"    => "ts",
    "mpegvideo" => "mpeg"
  }.freeze

  # Codec aliases used by clients (e.g. some list both "hevc" and "h265").
  CODEC_ALIASES = {
    "h265" => "hevc",
    "hevc" => "h265"
  }.freeze

  # Conservative default profile when a client doesn't send one. Mirrors a
  # universal H.264/AAC/mp4 baseline so every legacy client at least gets a
  # working transcode path. Production clients should always send their own
  # profile.
  DEFAULT_PROFILE = {
    "Name" => "default-fallback",
    "MaxStaticBitrate" => 1_000_000_000,
    "DirectPlayProfiles" => [
      {
        "Container" => "mp4,m4v,mov",
        "Type" => "Video",
        "VideoCodec" => "h264",
        "AudioCodec" => "aac"
      }
    ],
    "TranscodingProfiles" => [
      {
        "Container" => "mp4",
        "Type" => "Video",
        "Protocol" => "hls",
        "VideoCodec" => "h264",
        "AudioCodec" => "aac",
        "MaxAudioChannels" => "6"
      }
    ],
    "SubtitleProfiles" => [
      { "Format" => "vtt", "Method" => "External" }
    ],
    "CodecProfiles" => []
  }.freeze

  attr_reader :raw

  def initialize(profile)
    @raw = if profile.is_a?(Hash) && !profile.empty?
             profile
    else
             DEFAULT_PROFILE
    end
  end

  # ── Top-level decisions ─────────────────────────────────────────────

  # True when the file as configured (chosen audio + subtitle) can be
  # served as-is to the client. Used to pick :direct_play.
  def direct_play_match?(probe_result, audio_codec:, subtitle_format: nil)
    video_codec = probe_result.dig(:video, :codec)
    file_containers = expand_renames(container_tokens(probe_result[:formatName]), CONTAINER_RENAMES)

    direct_play_video_entries.any? do |entry|
      next false unless container_match?(file_containers, csv_value(entry, "Container"))
      next false unless csv_includes_codec?(entry, "VideoCodec", video_codec)
      next false if audio_codec && !csv_includes_codec?(entry, "AudioCodec", audio_codec)
      next false unless codec_profile_allows?("Video", video_codec, probe_result)
      next false if subtitle_format && subtitle_method_for(subtitle_format).nil?
      true
    end
  end

  # True when the video codec is in some DirectPlayProfile (and any
  # CodecProfiles for it pass). Used to pick :direct_stream when only the
  # container needs remuxing.
  def video_codec_supported?(video_codec, probe_result)
    return false if video_codec.blank?
    direct_play_video_entries.any? do |entry|
      csv_includes_codec?(entry, "VideoCodec", video_codec) &&
        codec_profile_allows?("Video", video_codec, probe_result)
    end
  end

  # True when the audio codec is in some DirectPlayProfile.
  def audio_codec_supported?(audio_codec)
    return false if audio_codec.blank?
    direct_play_video_entries.any? { |entry| csv_includes_codec?(entry, "AudioCodec", audio_codec) }
  end

  # Subtitle format → Method ("External" | "Embed") or nil if the client
  # can't render it (server must burn-in).
  def subtitle_method_for(format)
    return nil if format.blank?
    candidates = expand_renames([ format.to_s ], SUBTITLE_RENAMES)
    entry = subtitle_profiles.find do |p|
      formats = csv_value(p, "Format")
      candidates.any? { |c| formats.any? { |f| f.casecmp?(c) } }
    end
    entry && (entry["Method"] || entry[:Method])
  end

  # First TranscodingProfile entry for video. Tells the transcoder what to
  # produce when no direct path matches.
  def transcode_target
    entry = transcoding_profiles.find { |p| (p["Type"] || p[:Type]) == "Video" }
    return nil unless entry
    profile_to_target(entry)
  end

  # Pick the TranscodingProfile whose VideoCodec list contains the
  # source's video codec — used when we want to *copy* the source video
  # stream into the HLS output instead of re-encoding. Lets the server
  # honor Jellyfin's two-profile pattern: { Container: 'ts',
  # VideoCodec: 'h264' } for H.264 copy, { Container: 'mp4',
  # VideoCodec: 'h264,hevc,av1' } for codecs that need fMP4. When no
  # profile lists the source codec (or the client only sent one
  # profile), we fall back to `transcode_target` — the server will
  # re-encode to that profile's VideoCodec, which is the
  # full_transcode path. Source: jellyfin-web's browserDeviceProfile.js
  # emits both entries side-by-side and DynamicHlsController.cs picks
  # `segmentContainer` from whichever the source matches.
  def transcode_target_for(source_video_codec)
    return transcode_target if source_video_codec.blank?
    matching = transcoding_profiles.find do |p|
      (p["Type"] || p[:Type]) == "Video" &&
        csv_includes_codec?(p, "VideoCodec", source_video_codec)
    end
    matching ? profile_to_target(matching) : transcode_target
  end

  # ── Section accessors ───────────────────────────────────────────────

  def direct_play_profiles
    Array(@raw["DirectPlayProfiles"] || @raw[:DirectPlayProfiles])
  end

  def transcoding_profiles
    Array(@raw["TranscodingProfiles"] || @raw[:TranscodingProfiles])
  end

  def subtitle_profiles
    Array(@raw["SubtitleProfiles"] || @raw[:SubtitleProfiles])
  end

  def codec_profiles
    Array(@raw["CodecProfiles"] || @raw[:CodecProfiles])
  end

  private

  def profile_to_target(entry)
    {
      container: (entry["Container"] || entry[:Container] || "mp4").to_s,
      video_codec: csv_value(entry, "VideoCodec").first || "h264",
      audio_codec: csv_value(entry, "AudioCodec").first || "aac",
      max_audio_channels: (entry["MaxAudioChannels"] || entry[:MaxAudioChannels]).to_i,
      protocol: (entry["Protocol"] || entry[:Protocol] || "hls").to_s
    }
  end

  def direct_play_video_entries
    direct_play_profiles.select { |p| (p["Type"] || p[:Type]) == "Video" }
  end

  # Container match — any token from the file's format_name (split on ",")
  # equals (case-insensitive) any token from the profile's Container CSV,
  # after applying CONTAINER_RENAMES. ffprobe joins compatible demuxers
  # (e.g. "mov,mp4,m4a"); we treat each as a candidate.
  def container_match?(file_tokens, profile_csv)
    return false if file_tokens.empty? || profile_csv.empty?
    expanded_profile = expand_renames(profile_csv, CONTAINER_RENAMES)
    file_tokens.any? { |f| expanded_profile.any? { |p| f.casecmp?(p) } }
  end

  def container_tokens(format_name)
    return [] if format_name.blank?
    format_name.to_s.downcase.split(",").map(&:strip).reject(&:empty?)
  end

  # Expand each token through `renames`, returning the deduped union of raw
  # + renamed names. Mirrors expand_with_renames in JMP's device_profile.cpp.
  def expand_renames(tokens, renames)
    out = []
    seen = {}
    Array(tokens).each do |token|
      add = ->(s) {
        next if s.blank?
        unless seen[s]
          seen[s] = true
          out << s
        end
      }
      add.call(token)
      add.call(renames[token])
    end
    out
  end

  # CSV split, trimmed, blank-rejected. Both string and symbol keys
  # accepted because controllers parse JSON params with default Rails
  # string-key convention.
  def csv_value(entry, key)
    raw = entry[key] || entry[key.to_sym]
    return [] if raw.blank?
    raw.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # CSV-contains check with codec-alias awareness.
  def csv_includes_codec?(entry, key, value)
    return false if value.blank?
    listed = csv_value(entry, key)
    candidates = [ value, CODEC_ALIASES[value.to_s.downcase] ].compact
    listed.any? { |v| candidates.any? { |c| v.casecmp?(c) } }
  end

  # Apply CodecProfiles for a codec/type. Returns true if all relevant
  # IsRequired conditions pass (or there are no relevant profiles).
  def codec_profile_allows?(type, codec, probe_result)
    return true if codec.blank?
    relevant = codec_profiles.select do |cp|
      next false unless (cp["Type"] || cp[:Type]) == type
      candidates = csv_value(cp, "Codec")
      candidates.any? { |c|
        c.casecmp?(codec) || c.casecmp?(CODEC_ALIASES[codec.to_s.downcase].to_s)
      }
    end
    return true if relevant.empty?
    relevant.all? { |cp| evaluate_conditions(cp["Conditions"] || cp[:Conditions], probe_result) }
  end

  # Conditions: each must pass (or be IsRequired:false) for the codec to
  # remain eligible. Any IsRequired:true condition that fails rejects the
  # codec for direct play / direct stream.
  def evaluate_conditions(conditions, probe_result)
    Array(conditions).all? do |cond|
      property = (cond["Property"] || cond[:Property]).to_s
      condition = (cond["Condition"] || cond[:Condition]).to_s
      value = cond["Value"] || cond[:Value]
      is_required = cond["IsRequired"]
      is_required = cond[:IsRequired] if is_required.nil?
      is_required = true if is_required.nil?

      actual = property_value(property, probe_result)
      next true if actual.nil? && !is_required
      next false if actual.nil?

      compare(actual, condition, value, property)
    end
  end

  # ffprobe rate strings are formal fractions: "30000/1001" → 29.97,
  # "25/1" → 25, "0/0" → nil (unknown). Bare integers also accepted.
  def parse_framerate(raw)
    return nil if raw.blank?
    num, den = raw.to_s.split("/").map(&:to_f)
    return nil if num.nil? || num <= 0
    return num if den.nil? || den == 0
    (num / den).round(3)
  end

  def property_value(property, probe_result)
    case property
    when "VideoBitDepth"
      pix_fmt = probe_result.dig(:video, :pix_fmt).to_s
      return 10 if TEN_BIT_PIX_FMTS.include?(pix_fmt)
      8
    when "VideoLevel"
      # ffprobe-reported level_idc, codec-specific. HEVC: 120=4.0, 150=5.0,
      # 153=5.1, 156=5.2. H.264: 40=4.0, 51=5.1. Clients emit the same
      # integer in their CodecProfile VideoLevel conditions (mirrors the
      # `.LNNN` suffix from the canPlayType probe).
      probe_result.dig(:video, :level)
    when "VideoFramerate"
      # Parse ffprobe's "num/den" fraction strings into a float. r_frame_rate
      # is the stream's nominal rate; falls back to avg_frame_rate when
      # absent (some VFR sources). Returns nil when both are missing or
      # invalid so IsRequired conditions fail closed.
      parse_framerate(
        probe_result.dig(:video, :r_frame_rate) || probe_result.dig(:video, :avg_frame_rate),
      )
    when "VideoRangeType"
      # Stringly-typed HDR detection: PQ or HLG transfer ⇒ "HDR"; anything
      # else ⇒ "SDR". Clients without HDR display capability emit
      # { Property: 'VideoRangeType', Condition: 'Equals', Value: 'SDR' }
      # to force tonemap.
      transfer = probe_result.dig(:video, :color_transfer).to_s
      return "HDR" if %w[smpte2084 arib-std-b67].include?(transfer)
      "SDR"
    when "AudioChannels"
      # Reserved for future audio-channel constraints. Caller would need
      # to pass the chosen audio stream into evaluate_conditions; not
      # required for v1 since TranscodingProfiles.MaxAudioChannels caps
      # output channels at the audio_transcode step.
      nil
    end
  end

  # String properties (VideoRangeType) compare on case-insensitive equality;
  # everything else falls back to numeric comparison.
  STRING_PROPERTIES = %w[VideoRangeType].freeze

  def compare(actual, condition, value, property = nil)
    if STRING_PROPERTIES.include?(property.to_s)
      a = actual.to_s
      v = value.to_s
      case condition
      when "Equals"    then a.casecmp?(v)
      when "NotEquals" then !a.casecmp?(v)
      else false
      end
    else
      target = value.to_f
      actual_num = actual.to_f
      case condition
      when "Equals"           then actual_num == target
      when "NotEquals"        then actual_num != target
      when "LessThanEqual"    then actual_num <= target
      when "LessThan"         then actual_num <  target
      when "GreaterThanEqual" then actual_num >= target
      when "GreaterThan"      then actual_num >  target
      else false
      end
    end
  end
end
