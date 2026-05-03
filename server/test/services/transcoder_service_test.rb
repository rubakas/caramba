require "test_helper"

class TranscoderServiceTest < ActiveSupport::TestCase
  def probe_result(video_codec: "h264", audio_codec: "aac", format_name: "matroska,webm",
                   pix_fmt: "yuv420p", width: 1920, channels: 2, bitrate: nil,
                   color_transfer: nil)
    {
      formatName: format_name,
      bitrate: bitrate,
      video: {
        codec: video_codec,
        width: width,
        height: 1080,
        pix_fmt: pix_fmt,
        color_transfer: color_transfer
      },
      audioStreams: [ { index: 1, codec: audio_codec, channels: channels, language: "eng" } ],
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

  test "audio_transcode when hevc video and ac3 audio (no client AC3 support)" do
    assert_equal :audio_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "ac3"), 1, nil
      )
  end

  # ── Audio direct-pass when client supports the codec ──────────────

  test "AC3 audio + client reports audio.ac3 → direct_stream (audio passes through)" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "ac3", format_name: "matroska,webm"),
        1, nil, { h264: true, audio: { ac3: true } }
      )
  end

  test "EAC3 audio + client reports audio.eac3 → direct_play (browser-friendly container)" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "eac3",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2"),
        1, nil, { h264: true, audio: { eac3: true } }
      )
  end

  test "TrueHD audio is never direct-passable (no MSE support exists)" do
    assert_equal :audio_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "truehd"),
        1, nil, { h264: true, audio: { aac: true, ac3: true, eac3: true } }
      )
  end

  test "AAC always direct-passable even when codec_support has no audio map" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "aac"),
        1, nil, { h264: true }
      )
  end

  test "allowed_audio_codec?: nil codec_name returns false" do
    refute TranscoderService.send(:allowed_audio_codec?, nil, { audio: { ac3: true } })
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

  # ── HDR direct-stream when client supports 10-bit HEVC MSE ────────

  test "10-bit HEVC + hevc10 client support → direct_stream (HDR direct stream)" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "matroska,webm", pix_fmt: "yuv420p10le"),
        1, nil, { h264: true, hevc: true, hevc10: true }
      )
  end

  test "10-bit HEVC in mp4 + hevc10 client support → direct_play (no encoder, no segmentation)" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2", pix_fmt: "yuv420p10le"),
        1, nil, { h264: true, hevc: true, hevc10: true }
      )
  end

  test "10-bit HEVC + hevc10 false → still full_transcode (Electron / older browsers)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", pix_fmt: "yuv420p10le"),
        1, nil, { h264: true, hevc: true, hevc10: false }
      )
  end

  test "10-bit HEVC + hevc10 absent → still full_transcode (default-deny)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", pix_fmt: "yuv420p10le"),
        1, nil, { h264: true, hevc: true }
      )
  end

  test "hevc10 support does not bypass force_transcode" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", pix_fmt: "yuv420p10le"),
        1, nil, { h264: true, hevc: true, hevc10: true }, true
      )
  end

  test "hevc10 support does not bypass burn_subtitle_index" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", pix_fmt: "yuv420p10le"),
        1, 3, { h264: true, hevc: true, hevc10: true }
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

  # ── Source-aware video bitrate ────────────────────────────────────

  def find_arg(args, flag)
    idx = args.index(flag)
    idx && args[idx + 1]
  end

  test "full_transcode_video_args: targets source bitrate when below the cap" do
    probe = probe_result(width: 1920, bitrate: 8_000_000)
    args = TranscoderService.send(:full_transcode_video_args, probe)
    assert_equal "8000000", find_arg(args, "-b:v")
    assert_equal "12000000", find_arg(args, "-maxrate")
    assert_equal "24000000", find_arg(args, "-bufsize")
  end

  test "full_transcode_video_args: caps source bitrate at 1080p ceiling (20M)" do
    probe = probe_result(width: 1920, bitrate: 50_000_000)
    args = TranscoderService.send(:full_transcode_video_args, probe)
    assert_equal "20000000", find_arg(args, "-b:v")
    assert_equal "30000000", find_arg(args, "-maxrate")
  end

  test "full_transcode_video_args: 4K cap is 40M" do
    probe = probe_result(width: 3840, bitrate: 100_000_000)
    args = TranscoderService.send(:full_transcode_video_args, probe)
    assert_equal "40000000", find_arg(args, "-b:v")
  end

  test "full_transcode_video_args: falls back to cap when probe has no bitrate" do
    probe = probe_result(width: 1920, bitrate: nil)
    args = TranscoderService.send(:full_transcode_video_args, probe)
    assert_equal "20000000", find_arg(args, "-b:v")
  end

  test "full_transcode_video_args: includes -allow_sw 1 for software fallback" do
    probe = probe_result(width: 1920, bitrate: 8_000_000)
    args = TranscoderService.send(:full_transcode_video_args, probe)
    assert_equal "1", find_arg(args, "-allow_sw")
  end

  # ── Multi-channel AAC ─────────────────────────────────────────────

  test "audio_transcode_args: stereo source → 192k AAC, no -ac flag" do
    probe = probe_result(channels: 2)
    args = TranscoderService.send(:audio_transcode_args, probe, 1)
    assert_equal "192k", find_arg(args, "-b:a")
    assert_nil args.index("-ac"), "stereo source should not force a layout change"
  end

  test "audio_transcode_args: 5.1 source → 384k AAC, no downmix" do
    probe = probe_result(channels: 6)
    args = TranscoderService.send(:audio_transcode_args, probe, 1)
    assert_equal "384k", find_arg(args, "-b:a")
    assert_nil args.index("-ac"), "5.1 source should not force a layout change"
  end

  test "audio_transcode_args: 7.1 source → 384k AAC, downmixed to 6 channels" do
    probe = probe_result(channels: 8)
    args = TranscoderService.send(:audio_transcode_args, probe, 1)
    assert_equal "384k", find_arg(args, "-b:a")
    assert_equal "6", find_arg(args, "-ac")
  end

  test "audio_transcode_args: missing audio stream defaults to stereo 192k" do
    probe = probe_result(channels: 2)
    args = TranscoderService.send(:audio_transcode_args, probe, 99)
    assert_equal "192k", find_arg(args, "-b:a")
  end

  # ── HLS segment duration ──────────────────────────────────────────

  test "build_hls_ffmpeg_args: uses 6-second segments" do
    probe = probe_result(video_codec: "hevc", audio_codec: "aac")
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp", :direct_stream, probe, { audio_stream_index: 1 })
    assert_equal "6", find_arg(args, "-hls_time")
  end

  # ── HDR tonemap (PQ/HLG → SDR) ────────────────────────────────────

  test "hdr_source?: smpte2084 is HDR" do
    probe = probe_result(color_transfer: "smpte2084")
    assert TranscoderService.send(:hdr_source?, probe)
  end

  test "hdr_source?: arib-std-b67 (HLG) is HDR" do
    probe = probe_result(color_transfer: "arib-std-b67")
    assert TranscoderService.send(:hdr_source?, probe)
  end

  test "hdr_source?: bt709 is not HDR" do
    probe = probe_result(color_transfer: "bt709")
    refute TranscoderService.send(:hdr_source?, probe)
  end

  test "hdr_source?: missing transfer is not HDR" do
    probe = probe_result(color_transfer: nil)
    refute TranscoderService.send(:hdr_source?, probe)
  end

  # Helper: pin @zscale_available so tests don't depend on the local
  # ffmpeg binary. We restore the memo after the block.
  def with_zscale(available)
    prev = TranscoderService.instance_variable_get(:@zscale_available)
    TranscoderService.instance_variable_set(:@zscale_available, available)
    yield
  ensure
    TranscoderService.instance_variable_set(:@zscale_available, prev)
  end

  test "build_hls_ffmpeg_args: HDR full_transcode prepends tonemap chain to -vf" do
    with_zscale(true) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      vf = find_arg(args, "-vf")
      assert_includes vf, "zscale=t=linear:npl=100"
      assert_includes vf, "tonemap=tonemap=hable"
      assert_includes vf, "format=yuv420p"
      assert_equal "bt709", find_arg(args, "-color_primaries")
      assert_equal "bt709", find_arg(args, "-color_trc")
      assert_equal "bt709", find_arg(args, "-colorspace")
      assert_equal "tv", find_arg(args, "-color_range")
    end
  end

  test "build_hls_ffmpeg_args: SDR full_transcode does NOT add tonemap chain" do
    probe = probe_result(video_codec: "vc1", color_transfer: "bt709")
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe, { audio_stream_index: 1 })
    vf = find_arg(args, "-vf")
    refute_includes vf, "zscale"
    refute_includes vf, "tonemap"
    assert_nil find_arg(args, "-color_primaries"),
      "SDR sources must not be tagged with bt709 explicitly — preserves source metadata"
  end

  test "build_hls_ffmpeg_args: HDR + zscale unavailable falls back without tonemap" do
    with_zscale(false) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      vf = find_arg(args, "-vf")
      refute_includes vf, "zscale"
      refute_includes vf, "tonemap"
    end
  end

  # ── HDR + 4K downscale (CPU mitigation) ───────────────────────────

  test "HDR + 4K source downscales to 1080p before tonemap (CPU mitigation)" do
    with_zscale(true) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      vf = find_arg(args, "-vf")
      assert_includes vf, "scale=-2:1080:flags=lanczos"
      assert vf.index("scale=-2:1080") < vf.index("zscale=t=linear"),
        "downscale must precede tonemap so we tonemap 4× fewer pixels"
    end
  end

  test "HDR + 1080p source does NOT add downscale" do
    with_zscale(true) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 1920)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      refute_includes find_arg(args, "-vf"), "scale=-2:1080"
    end
  end

  test "SDR 4K source does NOT downscale (downscale only fires with tonemap)" do
    with_zscale(true) do
      probe = probe_result(video_codec: "vc1", color_transfer: "bt709", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      refute_includes find_arg(args, "-vf"), "scale=-2:1080"
    end
  end

  # ── Audio sync ────────────────────────────────────────────────────

  test "audio_transcode_args uses conservative aresample=async=1" do
    args = TranscoderService.send(:audio_transcode_args, probe_result(channels: 6), 1)
    assert_equal "aresample=async=1", find_arg(args, "-af")
  end

  test "audio_transcode_args pins sample rate to 48000" do
    args = TranscoderService.send(:audio_transcode_args, probe_result(channels: 6), 1)
    assert_equal "48000", find_arg(args, "-ar")
  end
end
