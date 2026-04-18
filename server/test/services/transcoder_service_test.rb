require "test_helper"

class TranscoderServiceTest < ActiveSupport::TestCase
  def probe_result(video_codec: "h264", audio_codec: "aac")
    {
      video: { codec: video_codec, width: 1920, height: 1080, pix_fmt: "yuv420p" },
      audioStreams: [ { index: 1, codec: audio_codec, channels: 2, language: "eng" } ],
      subtitleStreams: []
    }
  end

  test "direct_play when h264 video and aac audio" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(probe_result, 1, nil)
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
        probe_result(video_codec: "hevc", audio_codec: "aac"), 1, nil, nil, true
      )
  end
end
