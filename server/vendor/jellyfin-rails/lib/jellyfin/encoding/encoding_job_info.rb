require 'jellyfin/encoding/encoding_options'

module Jellyfin
  module Encoding
    # Ruby equivalent of Jellyfin's StreamState / EncodingJobInfo. Carries
    # everything EncodingHelper needs to build a complete ffmpeg arg list:
    #
    #   - input MediaSourceInfo (from probing)
    #   - which streams the client wants (video_track / audio_track / sub_track)
    #   - target codecs, bitrates, resolution
    #   - HLS segment length, base directory
    #   - the resolved EncodingOptions for HW accel preferences
    #
    # Mirrors the upstream class but is a plain POD instead of an OO god-object.
    class EncodingJobInfo
      OutputContainer = Struct.new(:name, :extension, keyword_init: true)

      DEFAULTS = {
        output_video_codec: 'libx264',
        output_audio_codec: 'aac',
        output_audio_channels: 2,
        output_audio_bitrate: 128_000,
        output_video_bitrate: 2_000_000,
        output_audio_sample_rate: 48_000,
        segment_length: 6,
        # mpegts is the historical default; HEVC/AV1 stream-copy paths
        # override to 'mp4' so ffmpeg emits fMP4 segments + the init.
        segment_container: 'ts',
        subtitle_method: :soft, # :soft | :encode (burn) | :embedded
        copy_timestamps: false,
        output_height: nil,
        output_width: nil
      }.freeze

      attr_accessor :media_source,
                    :video_stream,
                    :audio_stream,
                    :subtitle_stream,
                    :options,
                    :output_video_codec,
                    :output_audio_codec,
                    :output_audio_channels,
                    :output_audio_bitrate,
                    :output_video_bitrate,
                    :output_audio_sample_rate,
                    :output_height,
                    :output_width,
                    :segment_length,
                    # 'ts' (default, MPEG-TS) or 'mp4' (fMP4 — required
                    # for HEVC/AV1 stream-copy to Safari per upstream
                    # DynamicHlsController.cs:1596). Determines the
                    # `-hls_segment_type`, `-tag:v hvc1`, and
                    # `-hls_fmp4_init_filename` args downstream.
                    :segment_container,
                    :subtitle_method,
                    :copy_timestamps,
                    :start_time_ticks,
                    :max_framerate

      def initialize(media_source:, options: EncodingOptions.new, **overrides)
        @media_source = media_source
        @options = options
        DEFAULTS.each { |k, v| instance_variable_set(:"@#{k}", overrides.fetch(k, v)) }
        @video_stream    = overrides[:video_stream]    || media_source.default_video_stream
        @audio_stream    = overrides[:audio_stream]    || media_source.default_audio_stream
        @subtitle_stream = overrides[:subtitle_stream] || media_source.default_subtitle_stream
        @start_time_ticks = overrides[:start_time_ticks]
        @max_framerate    = overrides[:max_framerate]
      end

      def hdr_input?       = video_stream&.hdr?
      def hls?             = true # all phase-2 output is HLS; mp4/dash come later
      def hw_accel?        = options.hardware_acceleration?
      def burn_subtitles?  = subtitle_method == :encode && subtitle_stream
      def stream_copy_video? = output_video_codec == 'copy'
      def stream_copy_audio? = output_audio_codec == 'copy'

      # Mirror of upstream Jellyfin's EncodingJobInfo.ActualOutputVideoCodec
      # (MediaBrowser.Controller/MediaEncoding/EncodingJobInfo.cs:420). When
      # the output codec is `copy` we're remuxing — the bytes on the wire
      # carry the source codec, so that's what callers must announce
      # (HLS CODECS attribute, transcoding container negotiation, etc.).
      # Otherwise it's the configured target codec.
      #
      # Normalises encoder names (libx264, h264_videotoolbox, ...) to the
      # codec family (h264) so consumers don't have to special-case every
      # hwaccel variant.
      def actual_output_video_codec
        return nil unless video_stream
        return video_stream.codec if stream_copy_video?
        ENCODER_TO_CODEC_FAMILY[output_video_codec.to_s] || output_video_codec
      end

      def actual_output_audio_codec
        return nil unless audio_stream
        return audio_stream.codec if stream_copy_audio?
        ENCODER_TO_CODEC_FAMILY[output_audio_codec.to_s] || output_audio_codec
      end

      ENCODER_TO_CODEC_FAMILY = {
        'libx264' => 'h264', 'h264_videotoolbox' => 'h264',
        'h264_nvenc' => 'h264', 'h264_qsv' => 'h264',
        'h264_vaapi' => 'h264', 'h264_amf' => 'h264', 'h264_rkmpp' => 'h264',
        'libx265' => 'hevc', 'hevc_videotoolbox' => 'hevc',
        'hevc_nvenc' => 'hevc', 'hevc_qsv' => 'hevc',
        'hevc_vaapi' => 'hevc', 'hevc_amf' => 'hevc', 'hevc_rkmpp' => 'hevc',
        'libsvtav1' => 'av1', 'libaom-av1' => 'av1', 'av1_nvenc' => 'av1',
        'av1_qsv' => 'av1', 'av1_vaapi' => 'av1', 'av1_amf' => 'av1',
        'libfdk_aac' => 'aac',
        'libmp3lame' => 'mp3',
        'libopus' => 'opus'
      }.freeze
      private_constant :ENCODER_TO_CODEC_FAMILY
    end
  end
end
