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
    end
  end
end
