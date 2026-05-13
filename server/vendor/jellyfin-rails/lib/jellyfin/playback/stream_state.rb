module Jellyfin
  module Playback
    # Port of StreamingHelpers.GetStreamingState (StreamingHelpers.cs:45 —
    # the 600-line method). The upstream version takes a `StreamingRequestDto`,
    # an HTTP context, and N service references; produces a `StreamState`
    # carrying everything downstream code needs.
    #
    # Our equivalent collects what's currently scattered across the
    # PlaybackInfo + Transcoding controllers + TranscodeManager into a single
    # value object, populated by `StreamState.build`. Callers can then read
    # `state.video_stream`, `state.options`, etc. directly.
    class StreamState
      attr_reader :media_source, :profile, :video_stream, :audio_stream,
                  :subtitle_stream, :options,
                  :output_video_codec, :output_audio_codec,
                  :output_video_bitrate, :output_audio_bitrate,
                  :output_audio_channels, :output_height, :output_width,
                  :start_time_ticks, :run_time_ticks,
                  :play_session_id, :max_bitrate,
                  :decision

      # Mirrors GetStreamingState. Builds a state from the request hash and
      # the probed media source.
      def self.build(request:, media_source:, profile: nil, capabilities: nil)
        new(request: request, media_source: media_source,
            profile: profile, capabilities: capabilities).tap(&:resolve!)
      end

      def initialize(request:, media_source:, profile: nil, capabilities: nil)
        @request      = request
        @media_source = media_source
        @profile      = profile
        @capabilities = capabilities
      end

      # The heart of GetStreamingState — fills every output field.
      def resolve!
        r = @request

        @video_stream    = select_stream(@media_source.video_streams, r[:video_track])
        @audio_stream    = select_stream(@media_source.audio_streams, r[:audio_track])
        @subtitle_stream = r[:subtitle_track] && @media_source.subtitle_streams[r[:subtitle_track].to_i]

        # Codec resolution. If the caller didn't supply one, infer from the
        # container (upstream cs:155).
        @output_video_codec = (r[:video_codec] || infer_video_codec).to_s
        @output_audio_codec = (r[:audio_codec] || infer_audio_codec).to_s

        @output_video_bitrate  = (r[:video_bitrate] || 2_000_000).to_i
        @output_audio_bitrate  = (r[:audio_bitrate] || 128_000).to_i
        @output_audio_channels = r[:audio_channels]&.to_i
        @output_height         = r[:max_height]&.to_i
        @output_width          = r[:max_width]&.to_i

        @start_time_ticks      = r[:start_time_ticks]&.to_i
        @run_time_ticks        = @media_source.run_time_ticks
        @play_session_id       = r[:play_session_id]
        @max_bitrate           = MediaInfoHelper.get_max_bitrate(
          client_max_bitrate: r[:max_bitrate]&.to_i,
          remote_client_bitrate_limit: r[:remote_client_bitrate_limit].to_i,
          ip_address: r[:ip_address]
        )

        @options = build_encoding_options

        # Decision routing — upstream calls StreamBuilder.GetOptimal*Stream.
        @decision = if @profile
                      Decision.call(media_source: @media_source, profile: @profile,
                                    requested: { audio_track: r[:audio_track],
                                                 subtitle_track: r[:subtitle_track],
                                                 max_bitrate: @max_bitrate })
                    end

        self
      end

      # Mirrors the EncodingJobInfo construction inside the controllers.
      def to_job_info
        Jellyfin::Encoding::EncodingJobInfo.new(
          media_source: @media_source, options: @options,
          output_video_codec: @output_video_codec,
          output_audio_codec: @output_audio_codec,
          output_video_bitrate: @output_video_bitrate,
          output_audio_bitrate: @output_audio_bitrate,
          output_audio_channels: @output_audio_channels,
          output_height: @output_height, output_width: @output_width,
          start_time_ticks: @start_time_ticks,
          video_stream: @video_stream, audio_stream: @audio_stream,
          subtitle_stream: @subtitle_stream,
          subtitle_method: (@request[:subtitle_mode] || :soft).to_sym
        )
      end

      # IsSegmentedLiveStream port (EncodingJobInfo.cs:145).
      def segmented_live? = @run_time_ticks.nil? || @run_time_ticks.to_i.zero?

      private

      def select_stream(list, requested_index)
        return list.first if requested_index.nil?
        list[requested_index.to_i] || list.first
      end

      def infer_video_codec
        Jellyfin::Encoding::CodecInference.infer_video_codec(@media_source.path)
      end

      def infer_audio_codec
        Jellyfin::Encoding::CodecInference.infer_audio_codec(@media_source.container)
      end

      def build_encoding_options
        opts = Jellyfin::Encoding::EncodingOptions.new
        r = @request
        %i[auto_crop two_pass frame_interpolation target_framerate
           multi_audio_tracks force_accurate_seek enable_loudnorm enable_drc
           http_user_agent http_headers concat_parts].each do |k|
          opts.public_send("#{k}=", r[k]) if r.key?(k)
        end
        opts
      end
    end
  end
end
