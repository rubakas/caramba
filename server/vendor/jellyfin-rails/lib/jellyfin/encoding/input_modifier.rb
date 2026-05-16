require 'jellyfin/encoding/graphical_sub_canvas'

module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetInputModifier (cs:7216). Builds the args that
    # go BEFORE `-i input`. Upstream concatenates:
    #
    #   1. -analyzeduration
    #   2. -probesize
    #   3. -user_agent (for HTTP sources)
    #   4. -referer
    #   5. fast-seek -ss
    #   6. -rtsp_transport / -rtsp_flags (when input is rtsp)
    #   7. -async (audio sync mode)
    #   8. -re (when ReadInputAtNativeFramerate is set)
    #   9. -readrate / -readrate_catchup
    #  10. -fflags (input-side; e.g., +discardcorrupt for poor sources)
    #
    # Our equivalent pulls from `ProbeTuning`, `InputSource`, and `Seek` —
    # this module composes them through the upstream's canonical signature
    # so existing C# call patterns translate one-to-one.
    module InputModifier
      module_function

      def call(job:, segment_container: nil, encoding_options: nil)
        encoding_options ||= job.options
        args = []

        # 1+2. analyzeduration + probesize (Encoding::ProbeTuning).
        args.concat(Jellyfin::Encoding::ProbeTuning.input_args(job))

        # 3+4. user-agent / headers for HTTP sources (Encoding::InputSource handles them
        # as part of the input args; we extract just the modifiers here so they go in
        # the right order — modifiers before `-i`).
        if encoding_options.respond_to?(:http_user_agent) && encoding_options.http_user_agent
          args.concat(['-user_agent', encoding_options.http_user_agent])
        end
        if encoding_options.respond_to?(:http_referer) && encoding_options.http_referer
          args.concat(['-referer', encoding_options.http_referer])
        end

        # 5. Fast-seek -ss (Encoding::Seek decides pre- vs post-input; we want
        # ONLY the pre-input here since this is a modifier).
        plan = Jellyfin::Encoding::Seek.plan_for(job)
        args.concat(plan.pre_input)

        # 6. RTSP transport hints.
        if job.media_source.path.to_s.start_with?('rtsp:')
          args.concat(['-rtsp_transport', 'tcp+udp', '-rtsp_flags', 'prefer_tcp'])
        end

        # 7. Audio sync (upstream's InputAudioSync). Surfaced via EncodingOptions.
        if encoding_options.respond_to?(:input_audio_sync) && encoding_options.input_audio_sync
          args.concat(['-async', encoding_options.input_audio_sync.to_s])
        end

        # 8+9. -re / -readrate for live sources. Upstream conditionally applies
        # this based on ReadInputAtNativeFramerate + the encoder version. We
        # apply -re only for explicit live streams (matches our LiveStream class).
        if job.media_source.path.to_s.match?(/\A(rtsp|rtmp|udp|srt|rtp):/)
          args << '-re'
        end

        # 11. Graphical-subtitle canvas size. ffmpeg's PGS demuxer can't
        # auto-detect the bitmap canvas dimensions for some streams (it
        # logs "Could not find codec parameters for stream X (Subtitle:
        # hdmv_pgs_subtitle): unspecified size" and bails on the overlay
        # filter). Upstream Jellyfin emits `-canvas_size WxH` as an input
        # modifier (EncodingHelper.cs:1246, GetGraphicalSubCanvasSize).
        # The port had the helper file but no caller — the burn job
        # silently produced no usable segments (504s at the client) on
        # files like Office US S01E03 (HEVC 10-bit + PGS).
        args.concat(Jellyfin::Encoding::GraphicalSubCanvas.args(job))

        args
      end
    end
  end
end
