require 'spec_helper'
require 'jellyfin/encoding/encoding_helper'
require 'jellyfin/encoding/encoding_job_info'
require 'jellyfin/media_encoder/encoder'

# Regression coverage for the fMP4 stream-copy ffmpeg invocation. Mirrors
# upstream DynamicHlsController.cs:1596-1614 — when SegmentContainer is
# `mp4`, the muxer args MUST emit `-hls_segment_type fmp4`,
# `-hls_fmp4_init_filename ...`, `-tag:v hvc1` (so Apple players accept
# HEVC), and `-hls_segment_options movflags=+frag_discont` (so first-frag
# DTS/PTS keep the source timestamps and don't reset to 0).
#
# Bug this regresses: `segment_container` lived only on `TranscodingJob`;
# `TranscodeManager.build_args` constructed an `EncodingJobInfo` that
# didn't propagate it, so `EncodingHelper.hls_output_args` couldn't see
# it and silently fell back to mpegts. Effect: ffmpeg wrote MPEG-TS
# bytes into `*.mp4` filenames, never produced `-1.mp4`, and Safari's
# init segment fetch timed out at 10 s (504 Gateway Timeout).
RSpec.describe 'EncodingHelper HLS fMP4 args (regression)' do
  let(:caps) { Jellyfin::MediaEncoder::Encoder.capabilities }

  def make_info(segment_container:)
    video = Jellyfin::Probing::MediaStream.new(
      index: 0, type: :video, codec: 'hevc', profile: 'Main 10',
      width: 1920, height: 1080, frame_rate: 23.976,
      pixel_format: 'yuv420p10le', bit_depth: 10,
      sample_aspect_ratio: '1:1', is_interlaced: false,
      video_range_type: 'SDR', level: 120, bit_rate: 4_200_000
    )
    audio = Jellyfin::Probing::MediaStream.new(
      index: 1, type: :audio, codec: 'aac', channels: 6, sample_rate: 48_000
    )
    src = Jellyfin::Probing::MediaSourceInfo.new(
      path: '/tmp/sample.mkv', container: 'mkv', streams: [ video, audio ]
    )
    Jellyfin::Encoding::EncodingJobInfo.new(
      media_source: src,
      output_video_codec: 'copy',
      output_audio_codec: 'copy',
      segment_container: segment_container
    )
  end

  def args_for(segment_container:)
    info = make_info(segment_container: segment_container)
    Jellyfin::Encoding::EncodingHelper.command_line_arguments(
      info,
      playlist_path: '/tmp/transcodes/job/master.m3u8',
      segment_template: "/tmp/transcodes/job/%d.#{segment_container == 'mp4' ? 'mp4' : 'ts'}",
      capabilities: caps
    )
  end

  describe 'when segment_container is mp4 (fMP4)' do
    let(:args) { args_for(segment_container: 'mp4') }

    it 'emits fmp4 segment type' do
      expect(args).to include('-hls_segment_type', 'fmp4')
    end

    it 'emits -hls_fmp4_init_filename with the -1.mp4 init segment' do
      expect(args).to include('-hls_fmp4_init_filename', '-1.mp4')
    end

    it 'emits -tag:v hvc1 so Apple players accept HEVC sample entries' do
      # Without this, ffmpeg's fmp4 muxer writes `hev1` and Safari
      # rejects the segments — output ends up as 24-byte stub fragments.
      expect(args).to include('-tag:v', 'hvc1')
    end

    it 'emits movflags=+frag_discont (upstream DynamicHlsController.cs:1611)' do
      # fMP4 needs this flag to write packet DTS/PTS including the
      # initial delay into MOOF::TRAF::TFDT. Without it, ffmpeg resets
      # to 0-based timestamps and Safari can't reconcile with the
      # playlist's #EXTINF.
      expect(args).to include('-hls_segment_options', 'movflags=+frag_discont')
    end

    it 'does NOT apply hevc_mp4toannexb (only valid for mpegts output)' do
      # The Annex-B conversion is wrong for fMP4 — fragments keep the
      # original length-prefixed NAL form. Upstream gates on
      # `state.OutputContainer == "ts"` (EncodingHelper.cs:7636).
      expect(args).not_to include('hevc_mp4toannexb')
      expect(args).not_to include('h264_mp4toannexb')
    end
  end

  describe 'when segment_container defaults to ts (mpegts)' do
    let(:args) { args_for(segment_container: 'ts') }

    it 'emits mpegts segment type' do
      expect(args).to include('-hls_segment_type', 'mpegts')
    end

    it 'does NOT emit -hls_fmp4_init_filename or fmp4-only args' do
      expect(args).not_to include('-hls_fmp4_init_filename')
      expect(args).not_to include('movflags=+frag_discont')
    end
  end
end
