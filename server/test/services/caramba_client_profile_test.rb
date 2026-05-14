require "test_helper"

class CarambaClientProfileTest < ActiveSupport::TestCase
  # Regression for "every Caramba browser session ends up doing a full
  # h264_videotoolbox re-encode for HEVC 10-bit MKVs the client could
  # actually play via direct_stream remux". Symptom: each HLS segment
  # took ~6 s wall time to deliver in Safari's Network panel; the user
  # observed that the same file plays via direct_stream in upstream
  # Jellyfin without re-encoding.
  #
  # Root cause: `ClientProfile.modern_browser` defaults
  # `supports_10bit = false` to stay safe for legacy MSE pipelines.
  # Caramba's DeviceProfile builder only flips that to `true` by
  # NOT emitting a `VideoBitDepth <= 8` CodecProfile — but on Safari
  # both 8-bit and 10-bit MSE probes fail (Safari does HEVC via native
  # HLS, not MSE), so the bit-depth cap is never emitted AND the
  # default stays false. Decision then rejects 10-bit direct_stream
  # and falls all the way to full_transcode.
  #
  # Caramba now defaults `supports_10bit = true` in CarambaClientProfile
  # and lets an explicit `VideoBitDepth <= 8` CodecProfile flip it off.
  # Mirrors what jellyfin-web declares for Safari via
  # `hevcProfiles = 'main|main 10'` (browserDeviceProfile.js:1157).

  test "supports_10bit stays at the modern_browser default (false) until keyframe extraction lands" do
    # Until VodPlaylistGenerator builds its EXTINFs from real source
    # keyframes (matching upstream's `ComputeSegments`), HEVC 10-bit
    # stream-copy would produce a playlist whose `#EXTINF` values
    # don't match the actual variable-length segments ffmpeg's fmp4
    # HLS muxer emits (9.1s, 4.0s, 8.7s, 8.3s on the user's Office
    # S01E03 x265 rip). Safari rejects that mismatch with
    # MEDIA_ERR_DECODE. The fmp4 plumbing is wired through the engine
    # — we just don't flip the bit yet.
    device_profile = {
      "DirectPlayProfiles" => [],
      "CodecProfiles" => []
    }
    profile = CarambaClientProfile.build(device_profile)
    refute profile.supports_10bit
  end

  test "10-bit HEVC + AAC in MKV resolves to :transcode (until keyframe-aware playlist lands)" do
    device_profile = {
      "DirectPlayProfiles" => [
        { "Container" => "mp4,m4v,mov,mj2", "Type" => "Video",
          "VideoCodec" => "h264,hevc,h265", "AudioCodec" => "aac,mp3,opus" }
      ],
      "TranscodingProfiles" => [],
      "SubtitleProfiles" => [],
      "CodecProfiles" => [],
      "MaxStaticBitrate" => 1_000_000_000
    }
    profile = CarambaClientProfile.build(device_profile)

    video = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: "hevc", profile: "Main 10",
      width: 1920, height: 1040, frame_rate: 23.976,
      pixel_format: "yuv420p10le", bit_depth: 10,
      sample_aspect_ratio: "1:1", is_interlaced: false,
      video_range_type: "SDR", level: 120, bit_rate: 4_200_000
    )
    audio = Jellyfin::Probing::MediaStream.new(
      index: 1, type: :audio, codec: "aac", channels: 6
    )
    media_source = Jellyfin::Probing::MediaSourceInfo.new(
      path: "/x.mkv", container: "mkv", streams: [ video, audio ]
    )

    decision = Jellyfin::Playback::Decision.call(
      media_source: media_source, profile: profile
    )
    assert_equal :transcode, decision.mode
    assert_includes decision.reasons, "bit_depth_10"
  end
end
