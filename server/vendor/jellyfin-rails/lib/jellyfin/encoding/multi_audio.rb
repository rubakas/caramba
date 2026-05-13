module Jellyfin
  module Encoding
    # Multi-track audio output. Some clients (Apple TV, Plex) prefer when the
    # server emits multiple audio renditions in a single HLS playlist so the
    # user can switch tracks without re-buffering. ffmpeg supports this via
    # multiple `-map 0:a:N` + per-stream codec/bitrate flags.
    #
    # The default single-track behaviour from `EncodingHelper#audio_args` is
    # kept; this module is invoked when the job sets
    # `EncodingOptions#multi_audio_tracks = true` and the source has more than
    # one audio stream we want to expose.
    module MultiAudio
      module_function

      def enabled?(job)
        return false unless job.options.respond_to?(:multi_audio_tracks)
        return false unless job.options.multi_audio_tracks
        job.media_source.audio_streams.size > 1
      end

      # Returns the full audio block: per-track -map + -c:a:N + -b:a:N args.
      # `single_track_args` is the args we'd emit for a single track (so the
      # caller doesn't have to duplicate codec/bitrate selection).
      def args(job, single_track_args:)
        streams = job.media_source.audio_streams
        args = []
        streams.each_with_index do |stream, output_idx|
          source_idx = job.media_source.audio_streams.index(stream)
          args.concat(['-map', "0:a:#{source_idx}?"])
          # Per-stream encoder/bitrate flags. We reuse the same single-track
          # parameters for all tracks — fine for the common case where every
          # rendition is the same codec.
          single_track_args.each_with_index do |val, i|
            if %w[-c:a -b:a -ac -ar -channel_layout].include?(val)
              args << "#{val}:#{output_idx}"
            elsif single_track_args[i - 1]&.match?(/^-c:a$|^-b:a$|^-ac$|^-ar$|^-channel_layout$/)
              args << val
            end
          end
          # Per-track metadata so HLS can emit a NAME for the player to display.
          name = stream.language || stream.title || "Track #{output_idx + 1}"
          args.concat(["-metadata:s:a:#{output_idx}", "language=#{stream.language || 'und'}"])
          args.concat(["-metadata:s:a:#{output_idx}", "title=#{name}"])
        end
        args
      end
    end
  end
end
