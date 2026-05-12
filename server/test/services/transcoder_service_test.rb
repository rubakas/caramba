require "test_helper"
require "tempfile"

class TranscoderServiceTest < ActiveSupport::TestCase
  def probe_result(video_codec: "h264", audio_codec: "aac", format_name: "matroska,webm",
                   pix_fmt: "yuv420p", width: 1920, channels: 2, bitrate: nil,
                   color_transfer: nil, level: nil)
    {
      formatName: format_name,
      bitrate: bitrate,
      video: {
        codec: video_codec,
        width: width,
        height: 1080,
        pix_fmt: pix_fmt,
        level: level,
        color_transfer: color_transfer
      },
      audioStreams: [ { index: 1, codec: audio_codec, channels: channels, language: "eng" } ],
      subtitleStreams: []
    }
  end

  # ── DeviceProfile fixtures ────────────────────────────────────────
  #
  # Browser MSE profile, parametrized for the codec axes that drive strategy
  # decisions. `audio_codecs` is the comma-joined audio CSV; `hevc10` toggles
  # the CodecProfile bit-depth cap that the http.js builder adds when the
  # client (e.g. Electron 33) can't decode HEVC Main 10.
  def browser_profile(hevc10: true, audio_codecs: %w[aac], video_codecs: %w[h264 hevc h265])
    profile = {
      "Name" => "browser-test",
      "DirectPlayProfiles" => [
        {
          "Container" => "mp4,m4v,mov,mj2",
          "Type" => "Video",
          "VideoCodec" => video_codecs.join(","),
          "AudioCodec" => audio_codecs.join(",")
        }
      ],
      "TranscodingProfiles" => [
        { "Container" => "mp4", "Type" => "Video", "Protocol" => "hls",
          "VideoCodec" => "h264", "AudioCodec" => "aac" }
      ],
      "SubtitleProfiles" => [ { "Format" => "vtt", "Method" => "External" } ],
      "CodecProfiles" => []
    }
    unless hevc10
      profile["CodecProfiles"] << {
        "Type" => "Video",
        "Codec" => "hevc,h265",
        "Conditions" => [
          { "Property" => "VideoBitDepth", "Condition" => "LessThanEqual",
            "Value" => "8", "IsRequired" => true }
        ]
      }
    end
    profile
  end

  # ExoPlayer / native player. MKV in DirectPlayProfile.Container, broad
  # codec coverage, PGSSUB + ASS in SubtitleProfiles with Embed.
  def native_player_profile
    {
      "Name" => "native-player",
      "DirectPlayProfiles" => [ {
        "Container" => "mkv,webm,mp4,m4v,mov,ts,m2ts,avi",
        "Type" => "Video",
        "VideoCodec" => "h264,hevc,h265,vp9,av1",
        "AudioCodec" => "aac,ac3,eac3,truehd,dts,flac,mp3,opus"
      } ],
      "TranscodingProfiles" => [
        { "Container" => "mp4", "Type" => "Video", "Protocol" => "hls",
          "VideoCodec" => "h264", "AudioCodec" => "aac" }
      ],
      "SubtitleProfiles" => [
        { "Format" => "PGSSUB", "Method" => "Embed" },
        { "Format" => "ssa", "Method" => "Embed" },
        { "Format" => "vtt", "Method" => "External" }
      ],
      "CodecProfiles" => []
    }
  end

  # ── Strategy selection ────────────────────────────────────────────

  test "direct_play when h264 + aac inside a browser-friendly container" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "mov,mp4,m4a,3gp,3g2,mj2"), 1, nil, browser_profile
      )
  end

  test "direct_stream when codecs OK but container needs remuxing (MKV)" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "matroska,webm"), 1, nil, browser_profile
      )
  end

  test "audio_transcode when hevc video and ac3 audio (no client AC3 support)" do
    assert_equal :audio_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "ac3"), 1, nil, browser_profile
      )
  end

  test "AC3 audio + profile lists ac3 → direct_stream (audio passes through)" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "ac3", format_name: "matroska,webm"),
        1, nil, browser_profile(audio_codecs: %w[aac ac3])
      )
  end

  test "EAC3 audio + profile lists eac3 + browser-friendly container → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "eac3",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2"),
        1, nil, browser_profile(audio_codecs: %w[aac eac3])
      )
  end

  test "TrueHD audio is never direct-passable in browser profiles → audio_transcode" do
    assert_equal :audio_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "truehd"), 1, nil,
        browser_profile(audio_codecs: %w[aac ac3 eac3])
      )
  end

  test "AAC always direct-passable when profile is the basic browser default" do
    # Default browser profile lists AAC; mkv+h264+aac → direct_stream
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "h264", audio_codec: "aac"), 1, nil, browser_profile
      )
  end

  test "full_transcode when burn_subtitle_index present (overrides profile match)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(probe_result, 1, 3, browser_profile)
  end

  test "hevc + aac in mp4 → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2"),
        1, nil, browser_profile
      )
  end

  # ── HEVC 10-bit (bit-depth CodecProfile) ──────────────────────────

  test "10-bit HEVC → full_transcode when profile caps HEVC at 8-bit (Electron MSE)" do
    [ "matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2" ].each do |container|
      assert_equal :full_transcode,
        TranscoderService.transcode_strategy(
          probe_result(video_codec: "hevc", audio_codec: "aac",
                       format_name: container, pix_fmt: "yuv420p10le"),
          1, nil, browser_profile(hevc10: false)
        ),
        "expected full_transcode for 10-bit hevc in #{container} when hevc10 capped at 8-bit"
    end
  end

  test "10-bit HEVC + non-aac audio → full_transcode (bit-depth cap wins over audio)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "truehd", pix_fmt: "yuv420p10le"),
        1, nil, browser_profile(hevc10: false)
      )
  end

  test "10-bit HEVC + profile without bit-depth cap + mkv → direct_stream" do
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "matroska,webm", pix_fmt: "yuv420p10le"),
        1, nil, browser_profile(hevc10: true)
      )
  end

  test "10-bit HEVC + profile without bit-depth cap + mp4 → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a,3gp,3g2,mj2", pix_fmt: "yuv420p10le"),
        1, nil, browser_profile(hevc10: true)
      )
  end

  test "bit-depth cap does not bypass burn_subtitle_index" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac", pix_fmt: "yuv420p10le"),
        1, 3, browser_profile(hevc10: true)
      )
  end

  # ── VideoLevel CodecProfile (HEVC level cap) ──────────────────────

  def browser_profile_with_hevc_level_cap(max_level)
    profile = browser_profile
    profile["CodecProfiles"] << {
      "Type" => "Video",
      "Codec" => "hevc,h265",
      "Conditions" => [
        { "Property" => "VideoLevel", "Condition" => "LessThanEqual",
          "Value" => max_level.to_s, "IsRequired" => true }
      ]
    }
    profile
  end

  test "HEVC at level 5.1 with profile capped at level 5.0 → full_transcode" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", level: 153),
        1, nil, browser_profile_with_hevc_level_cap(150)
      )
  end

  test "HEVC at level 4.0 with profile capped at level 5.0 → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", level: 120),
        1, nil, browser_profile_with_hevc_level_cap(150)
      )
  end

  test "HEVC missing level + IsRequired cap → full_transcode (fail-closed)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", level: nil),
        1, nil, browser_profile_with_hevc_level_cap(150)
      )
  end

  # ── VideoRangeType CodecProfile (HDR tonemap routing) ─────────────

  def browser_profile_sdr_only
    profile = browser_profile
    profile["CodecProfiles"] << {
      "Type" => "Video",
      "Codec" => "hevc,h265",
      "Conditions" => [
        { "Property" => "VideoRangeType", "Condition" => "Equals",
          "Value" => "SDR", "IsRequired" => true }
      ]
    }
    profile
  end

  test "HDR (smpte2084) HEVC with SDR-only profile → full_transcode (tonemap)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", color_transfer: "smpte2084"),
        1, nil, browser_profile_sdr_only
      )
  end

  test "HLG HEVC with SDR-only profile → full_transcode (tonemap)" do
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", color_transfer: "arib-std-b67"),
        1, nil, browser_profile_sdr_only
      )
  end

  test "SDR HEVC (bt709) with SDR-only profile → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", color_transfer: "bt709"),
        1, nil, browser_profile_sdr_only
      )
  end

  test "missing color_transfer treated as SDR with SDR-only profile → direct_play" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac",
                     format_name: "mov,mp4,m4a", color_transfer: nil),
        1, nil, browser_profile_sdr_only
      )
  end

  # ── Native-player profile (ExoPlayer-class) ───────────────────────

  test "native-player profile + mkv + hevc + truehd → direct_play (broad codec coverage)" do
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "truehd",
                     format_name: "matroska,webm", pix_fmt: "yuv420p10le"),
        1, nil, native_player_profile
      )
  end

  # ── Default profile (no client-supplied profile) ──────────────────

  test "missing profile falls back to default (h264 + aac + mp4 only)" do
    # h264/aac/mp4 → direct_play under the default
    assert_equal :direct_play,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "mov,mp4,m4a"), 1, nil, nil
      )
    # h264/aac/mkv → direct_stream (container mismatch only)
    assert_equal :direct_stream,
      TranscoderService.transcode_strategy(
        probe_result(format_name: "matroska,webm"), 1, nil, nil
      )
    # hevc/aac → full_transcode (default doesn't list hevc)
    assert_equal :full_transcode,
      TranscoderService.transcode_strategy(
        probe_result(video_codec: "hevc", audio_codec: "aac"), 1, nil, nil
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

  # Returns the base video filter chain — `-vf` value when single-rendition,
  # else the pre-split portion of `-filter_complex` (multi-rendition wraps
  # the same base chain then splits N ways for the ladder). Tests that
  # assert "tonemap is/isn't applied to the base chain" should compare
  # against this rather than the raw -vf, which goes away in the ladder
  # path.
  def find_video_filter(args)
    vf = find_arg(args, "-vf")
    return vf if vf
    fc = find_arg(args, "-filter_complex")
    return nil unless fc
    m = fc.match(/\A\[0:v:0\](.*?)\[v_split\]/m)
    m ? m[1] : fc
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

  test "build_hls_ffmpeg_args: HDR full_transcode prepends tonemap chain to base filter" do
    with_zscale(true) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      vf = find_video_filter(args)
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
    vf = find_video_filter(args)
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
      vf = find_video_filter(args)
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
      vf = find_video_filter(args)
      assert_includes vf, "scale=-2:1080:flags=lanczos"
      assert vf.index("scale=-2:1080") < vf.index("zscale=t=linear"),
        "downscale must precede tonemap so we tonemap 4× fewer pixels"
    end
  end

  test "HDR + 1080p source does NOT add base-filter downscale" do
    with_zscale(true) do
      probe = probe_result(video_codec: "hevc", pix_fmt: "yuv420p10le",
                           color_transfer: "smpte2084", width: 1920)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      # Base filter (pre-split) must not pre-downscale 1080p sources.
      # The ladder's per-variant scale=-2:1080 step lives after the split
      # and is a no-op when source is already 1080p.
      refute_includes find_video_filter(args), "scale=-2:1080"
    end
  end

  test "SDR 4K source does NOT downscale in base filter (downscale only with tonemap)" do
    with_zscale(true) do
      probe = probe_result(video_codec: "vc1", color_transfer: "bt709", width: 3840)
      args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                    :full_transcode, probe, { audio_stream_index: 1 })
      refute_includes find_video_filter(args), "scale=-2:1080"
    end
  end

  # ── Multi-rendition HLS ladder ────────────────────────────────────

  test "transcode_ladder: 4K source produces 3 renditions (1080p, 720p, 480p)" do
    probe = probe_result(width: 3840, bitrate: 25_000_000)
    ladder = TranscoderService.send(:transcode_ladder, probe)
    heights = ladder.map { |r| r[:height] }
    assert_equal [ 1080, 720, 480 ], heights
  end

  test "transcode_ladder: 1080p source produces 2 renditions (1080p, 480p)" do
    probe = probe_result(width: 1920, bitrate: 10_000_000)
    ladder = TranscoderService.send(:transcode_ladder, probe)
    heights = ladder.map { |r| r[:height] }
    assert_equal [ 1080, 480 ], heights
  end

  test "transcode_ladder: 720p source produces no ladder (single rendition)" do
    probe = probe_result(width: 1280, bitrate: 5_000_000)
    ladder = TranscoderService.send(:transcode_ladder, probe)
    # 1280 < 1800 → single rendition (downshifting to 480p offers no real
    # ABR benefit when source is already at 720p)
    assert_empty ladder
  end

  test "transcode_ladder: SD source produces empty ladder (single rendition path)" do
    probe = probe_result(width: 854, bitrate: 1_500_000)
    ladder = TranscoderService.send(:transcode_ladder, probe)
    assert_empty ladder
  end

  test "transcode_ladder: 1080p rendition caps at source bitrate when below 20M ceiling" do
    probe = probe_result(width: 3840, bitrate: 12_000_000)
    ladder = TranscoderService.send(:transcode_ladder, probe)
    rendition_1080 = ladder.find { |r| r[:height] == 1080 }
    assert_equal 12_000_000, rendition_1080[:bitrate]
  end

  test "build_hls_ffmpeg_args: multi-rendition emits var_stream_map with named variants" do
    probe = probe_result(video_codec: "vc1", width: 3840)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe, { audio_stream_index: 1 })
    var_stream_map = find_arg(args, "-var_stream_map")
    refute_nil var_stream_map
    assert_includes var_stream_map, "name:1080p"
    assert_includes var_stream_map, "name:720p"
    assert_includes var_stream_map, "name:480p"
    # Audio shared via agroup so it's encoded once across all variants.
    assert_includes var_stream_map, "agroup:au"
  end

  test "build_hls_ffmpeg_args: multi-rendition emits master_pl_name" do
    probe = probe_result(video_codec: "vc1", width: 3840)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe, { audio_stream_index: 1 })
    assert_equal "master.m3u8", find_arg(args, "-master_pl_name")
  end

  test "build_hls_ffmpeg_args: multi-rendition uses init_%v.mp4 init filename" do
    probe = probe_result(video_codec: "vc1", width: 3840)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe, { audio_stream_index: 1 })
    assert_equal "init_%v.mp4", find_arg(args, "-hls_fmp4_init_filename")
  end

  test "build_hls_ffmpeg_args: SD source falls back to single-rendition (no ladder)" do
    probe = probe_result(video_codec: "vc1", width: 854)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe, { audio_stream_index: 1 })
    assert_nil find_arg(args, "-var_stream_map"),
      "SD sources don't benefit from a ladder — single rendition stays single"
    assert_equal "init.mp4", find_arg(args, "-hls_fmp4_init_filename")
  end

  test "build_hls_ffmpeg_args: burn_sub forces single-rendition (no ladder under overlay)" do
    probe = probe_result(video_codec: "vc1", width: 3840)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :full_transcode, probe,
                                  { audio_stream_index: 1, burn_subtitle_index: 3 })
    assert_nil find_arg(args, "-var_stream_map"),
      "burn-in overlay uses a single filter_complex output — no ladder split"
  end

  test "build_hls_ffmpeg_args: audio_transcode does NOT use ladder (no video re-encode)" do
    probe = probe_result(video_codec: "h264", audio_codec: "truehd", width: 3840)
    args = TranscoderService.send(:build_hls_ffmpeg_args, "/path", 0, "/tmp",
                                  :audio_transcode, probe, { audio_stream_index: 1 })
    assert_nil find_arg(args, "-var_stream_map")
  end

  # ── Encode-speed monitoring (Sentry breadcrumbs) ──────────────────

  test "monitor_ffmpeg_stderr writes stderr lines to the log file" do
    Tempfile.create("ffmpeg_test_stderr") do |log_tmp|
      rd, wr = IO.pipe
      wr.write "frame= 100 fps= 25 speed=1.5x\n"
      wr.write "frame= 200 fps= 25 speed=1.6x\n"
      wr.close

      probe = probe_result(width: 1920, color_transfer: nil)
      thread = Thread.new {
        TranscoderService.send(:monitor_ffmpeg_stderr, rd, log_tmp.path,
                               :full_transcode, probe, "test-session")
      }
      thread.join(2)

      content = File.read(log_tmp.path)
      assert_includes content, "speed=1.5x"
      assert_includes content, "speed=1.6x"
    end
  end

  # Temporarily replace the report_encode_speed_degraded singleton with
  # a recording proxy so we can assert on what the stderr monitor reports.
  def with_speed_report_recorder
    recorded = []
    original = TranscoderService.singleton_class.instance_method(:report_encode_speed_degraded)
    TranscoderService.define_singleton_method(:report_encode_speed_degraded) do |mean, samples, strategy, probe, session|
      recorded << { mean: mean, samples: samples, strategy: strategy, session: session }
    end
    begin
      yield recorded
    ensure
      TranscoderService.define_singleton_method(:report_encode_speed_degraded, original)
    end
  end

  test "monitor_ffmpeg_stderr fires Sentry breadcrumb when speed degrades" do
    Tempfile.create("ffmpeg_test_stderr") do |log_tmp|
      rd, wr = IO.pipe
      # 5 samples below 0.9× — should trigger breadcrumb.
      5.times { |i| wr.write "frame=#{100 + i} fps= 25 speed=0.5x\n" }
      wr.close

      with_speed_report_recorder do |recorded|
        probe = probe_result(width: 1920)
        thread = Thread.new {
          TranscoderService.send(:monitor_ffmpeg_stderr, rd, log_tmp.path,
                                 :full_transcode, probe, "session-X")
        }
        thread.join(2)

        assert_equal 1, recorded.length
        assert_in_delta 0.5, recorded[0][:mean], 0.01
        assert_equal :full_transcode, recorded[0][:strategy]
        assert_equal "session-X", recorded[0][:session]
      end
    end
  end

  test "monitor_ffmpeg_stderr does NOT fire when speed stays above threshold" do
    Tempfile.create("ffmpeg_test_stderr") do |log_tmp|
      rd, wr = IO.pipe
      10.times { |i| wr.write "frame=#{100 + i} fps= 25 speed=1.5x\n" }
      wr.close

      with_speed_report_recorder do |recorded|
        probe = probe_result(width: 1920)
        thread = Thread.new {
          TranscoderService.send(:monitor_ffmpeg_stderr, rd, log_tmp.path,
                                 :full_transcode, probe, "session-Y")
        }
        thread.join(2)

        assert_empty recorded
      end
    end
  end

  test "monitor_ffmpeg_stderr does NOT fire after fewer than 5 degraded samples" do
    Tempfile.create("ffmpeg_test_stderr") do |log_tmp|
      rd, wr = IO.pipe
      # Only 4 degraded samples — below the rolling-window size.
      4.times { wr.write "frame= 100 fps= 25 speed=0.5x\n" }
      wr.close

      with_speed_report_recorder do |recorded|
        probe = probe_result(width: 1920)
        thread = Thread.new {
          TranscoderService.send(:monitor_ffmpeg_stderr, rd, log_tmp.path,
                                 :full_transcode, probe, "session-Z")
        }
        thread.join(2)

        assert_empty recorded
      end
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
