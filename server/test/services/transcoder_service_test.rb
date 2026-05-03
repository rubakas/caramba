require "test_helper"

class TranscoderServiceTest < ActiveSupport::TestCase
  def probe_result(video_codec: "h264", audio_codec: "aac", format_name: "matroska,webm", pix_fmt: "yuv420p")
    {
      formatName: format_name,
      video: { codec: video_codec, width: 1920, height: 1080, pix_fmt: pix_fmt },
      audioStreams: [ { index: 1, codec: audio_codec, channels: 2, language: "eng" } ],
      subtitleStreams: []
    }
  end

  test "direct_play when h264 + aac inside a browser-friendly container" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "mov,mp4,m4a,3gp,3g2,mj2"), 1, nil
      )
  end

  test "direct_stream when codecs OK but container needs remuxing (MKV)" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "matroska,webm"), 1, nil
      )
  end

  test "audio_transcode when hevc video and ac3 audio" do
    assert_equal :audio_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "ac3"), 1, nil
      )
  end

  test "full_transcode when burn_subtitle_index present" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(probe_result, 1, 3)
  end

  test "force_transcode overrides everything" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(probe_result, 1, nil, nil, true)
  end

  test "force_transcode overrides hevc direct_play too" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", format_name: "mov,mp4,m4a,3gp,3g2,mj2"),
        1, nil, nil, true
      )
  end

  test "hevc + aac in mp4 → direct_play (no transcode)" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", format_name: "mov,mp4,m4a,3gp,3g2,mj2"),
        1, nil
      )
  end

  # Pinned by the @smoke electron Playwright test on Aladdin (4K HEVC HDR).
  # Chromium MSE on Electron 33 accepts the codec string for HEVC Main 10 but
  # stalls on the decode itself. Re-encode to 8-bit H.264.
  test "10-bit HEVC (Main 10) → full_transcode regardless of container" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "matroska,webm", pix_fmt: "yuv420p10le"),
        1, nil
      )

    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2", pix_fmt: "yuv420p10le"),
        1, nil
      )
  end

  test "10-bit HEVC + non-aac audio → full_transcode (10-bit guard wins over audio_transcode)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "truehd", pix_fmt: "yuv420p10le"),
        1, nil
      )
  end

  # Regression pin: forcing -tag:v hvc1 broke the @smoke electron playback
  # test on Aladdin (HEVC Main 10 HDR) — readyState went to 4 with currentTime
  # stuck. ffmpeg's default `hev1` tag plays correctly on Electron 33 /
  # Chromium 130 / macOS via VideoToolbox.
  test "build_hls_ffmpeg_args: HEVC copy does NOT force hvc1 tag" do
    probe = probe_result(video_codec: "hevc", audio_codec: "aac")
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp", :direct_stream, probe, { audio_stream_index: 1 })
    assert_nil args.index("-tag:v"), "must NOT force hvc1 — see comment in transcoder_service.rb"
  end
end
