require 'jellyfin/playback/decision'
require 'jellyfin/playback/client_profile'

module Jellyfin
  module Playback
    # PlaybackInfo orchestrator. Mirrors MediaInfoController.GetPostedPlaybackInfo:
    # takes a media source + a client profile and returns the playable methods
    # plus the URLs the client should hit.
    #
    # The Decision module already answers "can this client direct-play?"; this
    # module just packages the answer for the HTTP layer.
    module PlaybackInfo
      Response = Struct.new(:method, :direct_play_url, :transcoding_url,
                            :transcoding_container, :subtitle_method,
                            :stream_id, :media_source, :reasons,
                            keyword_init: true) do
        def to_h_serializable
          {
            method: method.to_s,
            direct_play_url: direct_play_url,
            transcoding_url: transcoding_url,
            transcoding_container: transcoding_container,
            subtitle_method: subtitle_method,
            stream_id: stream_id,
            reasons: reasons || []
          }.compact
        end
      end

      module_function

      def for(media_source:, profile:, audio_track: nil, subtitle_track: nil,
              max_bitrate: nil, base_url: nil, token_for_direct: nil, token_for_transcode: nil)
        decision = Decision.call(
          media_source: media_source,
          profile: profile,
          requested: {
            audio_track: audio_track,
            subtitle_track: subtitle_track,
            max_bitrate: max_bitrate
          }
        )

        # Mirror upstream Jellyfin's MediaInfoHelper.cs:268-313: DirectStream
        # is served through the SAME HLS pipeline as Transcode (just with
        # `-c copy` instead of re-encoding). Both modes therefore need a
        # transcoding URL — only DirectPlay bypasses the engine entirely.
        # Without this branch, direct_stream decisions returned `null` URLs
        # for both fields and clients had nothing to load.
        needs_hls_url = decision.transcode? || decision.direct_stream?

        Response.new(
          method: decision.mode,
          direct_play_url: decision.direct_play? ? "#{base_url}/stream/#{token_for_direct}" : nil,
          transcoding_url: needs_hls_url ? "#{base_url}/transcode/#{token_for_transcode}/master.m3u8" : nil,
          transcoding_container: needs_hls_url ? 'hls' : nil,
          subtitle_method: subtitle_method_for(decision, subtitle_track),
          stream_id: media_source.id,
          media_source: media_source,
          reasons: decision.reasons
        )
      end

      def subtitle_method_for(decision, requested_track)
        return nil unless requested_track
        # Burn-in only when we're actually re-encoding the video. DirectStream
        # remuxes the source untouched so embedded subs survive — external VTT
        # works the same as for DirectPlay.
        decision.transcode? ? :encode : :external
      end
    end
  end
end
