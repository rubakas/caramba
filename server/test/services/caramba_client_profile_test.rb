require "test_helper"

class CarambaClientProfileTest < ActiveSupport::TestCase
  # Regression for "every Caramba browser session does a full
  # h264_videotoolbox re-encode for HEVC 10-bit MKVs the client could
  # actually play via direct_stream remux". Symptom: each HLS segment
  # took ~6 s wall time to deliver in Safari's Network panel; same file
  # plays via direct_stream in upstream Jellyfin without re-encoding.
  #
  # `ClientProfile.modern_browser` defaults `supports_10bit = false` to
  # stay safe for legacy MSE pipelines. CarambaClientProfile now flips
  # it to `true` and relies on an explicit `VideoBitDepth <= 8`
  # CodecProfile from clients that genuinely can't decode 10-bit
  # (Electron 33 / Chromium 130 MSE) to flip it back off. Mirrors what
  # jellyfin-web declares for Safari via `hevcProfiles = 'main|main 10'`
  # (browserDeviceProfile.js:1157). The companion change reads MKV
  # Cues via `Jellyfin::Keyframes::Extractor` so the variant playlist's
  # `#EXTINF` values match ffmpeg's `-c copy` segment durations.

  test "supports_10bit defaults to true so Safari can direct_stream HEVC 10-bit" do
    device_profile = {
      "DirectPlayProfiles" => [],
      "CodecProfiles" => []
    }
    profile = CarambaClientProfile.build(device_profile)
    assert profile.supports_10bit
  end

  test "an explicit VideoBitDepth <= 8 condition still disables 10-bit" do
    # Electron 33 / Chromium 130 MSE accepts the HEVC 10-bit codec
    # string but never produces frames. The client's DeviceProfile
    # carries a `VideoBitDepth <= 8` CodecProfile for exactly this case.
    device_profile = {
      "DirectPlayProfiles" => [],
      "CodecProfiles" => [
        {
          "Type" => "Video",
          "Codec" => "hevc,h265",
          "Conditions" => [
            { "Property" => "VideoBitDepth", "Condition" => "LessThanEqual", "Value" => "8" }
          ]
        }
      ]
    }
    profile = CarambaClientProfile.build(device_profile)
    refute profile.supports_10bit
  end

  test "10-bit HEVC + AAC in MKV resolves to :direct_stream" do
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
    assert_equal :direct_stream, decision.mode
  end
end
