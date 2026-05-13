require 'jellyfin/playback/client_profile'

module Jellyfin
  module Playback
    # Direct play / direct stream / transcode decision tree.
    # Mirrors MediaSourceInfo.SupportsDirectPlay / SupportsDirectStream from
    # MediaBrowser.Model.Dlna (slimmed down — full DLNA constraint system is
    # deferred). The result picks the cheapest viable delivery method:
    #
    #   :direct_play   — serve the original file with HTTP Range (no ffmpeg)
    #   :direct_stream — `ffmpeg -i in -c copy -f new_container out` (remux, no re-encode)
    #   :transcode     — full transcode through EncodingHelper
    #
    # The Decision object carries the reasons each cheaper mode was rejected,
    # which we use for diagnostics and for the /_status endpoint.
    class Decision
      Result = Struct.new(:mode, :container, :reasons, :video_stream, :audio_stream,
                          keyword_init: true) do
        def direct_play?   = mode == :direct_play
        def direct_stream? = mode == :direct_stream
        def transcode?     = mode == :transcode
      end

      def self.call(media_source:, profile:, requested: {})
        new(media_source: media_source, profile: profile, requested: requested).call
      end

      def initialize(media_source:, profile:, requested: {})
        @source    = media_source
        @profile   = profile
        @requested = requested
        @reasons   = []
      end

      def call
        v = @source.default_video_stream
        a = @source.default_audio_stream

        if direct_play_ok?(v, a)
          Result.new(mode: :direct_play, container: @source.container,
                     reasons: @reasons.dup, video_stream: v, audio_stream: a)
        elsif direct_stream_ok?(v, a)
          target_container = remux_target_container
          Result.new(mode: :direct_stream, container: target_container,
                     reasons: @reasons.dup, video_stream: v, audio_stream: a)
        else
          Result.new(mode: :transcode, container: 'mp4',
                     reasons: @reasons.dup, video_stream: v, audio_stream: a)
        end
      end

      private

      def direct_play_ok?(v, a)
        return reject(:no_streams) unless v || a
        return reject(:container, @source.container) unless @profile.containers.include?(@source.container.to_s)
        return false unless video_compatible?(v)
        return false unless audio_compatible?(a)
        true
      end

      def direct_stream_ok?(v, a)
        return false unless video_compatible?(v)
        return false unless audio_compatible?(a)
        # Container is the only blocker — remux can fix that.
        true
      end

      def video_compatible?(stream)
        return true if stream.nil?
        return reject(:video_codec, stream.codec) unless codec_match?(stream.codec, @profile.video_codecs)
        return reject(:video_height, stream.height) if @profile.max_video_height && stream.height && stream.height > @profile.max_video_height
        return reject(:video_width, stream.width)   if @profile.max_video_width  && stream.width  && stream.width  > @profile.max_video_width
        return reject(:video_fps, stream.frame_rate) if @profile.max_video_fps && stream.frame_rate && stream.frame_rate > @profile.max_video_fps + 0.5
        return reject(:video_bitrate, stream.bit_rate) if too_high?(stream.bit_rate, @profile.max_video_bitrate)
        return reject(:hdr) if stream.hdr? && !@profile.supports_hdr
        return reject(:dovi) if stream.video_range_type.to_s == 'DOVI' && !@profile.supports_dovi
        return reject(:bit_depth_10) if ten_bit?(stream) && !@profile.supports_10bit
        return reject(:anamorphic) if anamorphic?(stream) && !@profile.supports_anamorphic
        return reject(:interlaced) if stream.is_interlaced && !@profile.supports_interlaced
        return reject(:h264_profile, stream.profile) unless h264_profile_ok?(stream)
        return reject(:h264_level,   stream.level)   unless h264_level_ok?(stream)
        return reject(:hevc_profile, stream.profile) unless hevc_profile_ok?(stream)
        true
      end

      def audio_compatible?(stream)
        return true if stream.nil?
        return reject(:audio_codec, stream.codec) unless codec_match?(stream.codec, @profile.audio_codecs)
        return reject(:audio_channels, stream.channels) if @profile.max_audio_channels && stream.channels && stream.channels > @profile.max_audio_channels
        true
      end

      def codec_match?(codec, list)
        return false if codec.nil?
        c = codec.to_s.downcase
        list.any? { |k| codec_alias?(c, k) }
      end

      def codec_alias?(a, b)
        return true if a == b
        eq = [%w[h264 avc], %w[hevc h265 h.265], %w[av1 av01]]
        eq.any? { |g| g.include?(a) && g.include?(b) }
      end

      def too_high?(a, max)
        a && max && a > max
      end

      def ten_bit?(stream)
        stream.pixel_format.to_s.include?('10') || stream.bit_depth.to_i == 10
      end

      def anamorphic?(stream)
        sar = stream.sample_aspect_ratio.to_s
        !sar.empty? && sar != '1:1' && sar != '0:1'
      end

      def h264_profile_ok?(stream)
        return true unless stream.codec.to_s.downcase == 'h264'
        return true if @profile.h264_profiles.empty?
        @profile.h264_profiles.include?(stream.profile.to_s.downcase)
      end

      def h264_level_ok?(stream)
        return true unless stream.codec.to_s.downcase == 'h264'
        return true unless @profile.h264_level
        return true if stream.level.nil?
        stream.level <= @profile.h264_level
      end

      def hevc_profile_ok?(stream)
        return true unless %w[hevc h265].include?(stream.codec.to_s.downcase)
        # Empty list means "no profile constraint, accept any" — matches
        # `h264_profile_ok?` above and upstream Jellyfin's behaviour
        # (CodecProfile with no Conditions = no restriction). The port
        # previously returned false on empty, which made HEVC sources
        # un-direct-streamable to any client that didn't explicitly
        # populate `hevc_profiles` — that's nearly every client, since
        # browsers reach Safari native HLS without a Main10 probe path.
        return true if @profile.hevc_profiles.empty?
        @profile.hevc_profiles.include?(stream.profile.to_s.downcase.gsub(/[^a-z0-9]/, ''))
      end

      def remux_target_container
        # Prefer mp4 when the client accepts it; fall back to whatever the
        # client lists first.
        return 'mp4' if @profile.containers.include?('mp4')
        @profile.containers.first || 'mp4'
      end

      def reject(reason, value = nil)
        @reasons << (value ? "#{reason}=#{value}" : reason.to_s)
        false
      end
    end
  end
end
