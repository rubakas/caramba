module Jellyfin
  module Transcoding
    # Phase 2: hand-rolled minimum-viable ffmpeg arg builder for HLS output.
    # Software-only H.264/AAC; no HDR tonemap, no hardware accel, no subtitle burn-in.
    #
    # Replaced in phase 5 by the full EncodingHelper port. The interface
    # (`#call(playlist_path:, segment_template:)`) stays stable so the swap is local.
    class ArgsBuilder
      DEFAULT_PARAMS = {
        video_codec: 'libx264',
        video_bitrate: 2_000_000,
        audio_codec: 'aac',
        audio_bitrate: 128_000,
        max_height: nil,
        segment_length: 6
      }.freeze

      def initialize(params)
        @params = DEFAULT_PARAMS.merge(params.compact)
      end

      def call(playlist_path:, segment_template:)
        args = ['-hide_banner', '-loglevel', 'warning', '-y']
        args += ['-fflags', '+genpts']
        args += ['-i', @params[:path]]
        args += map_args
        args += video_args
        args += audio_args
        args += hls_args(playlist_path: playlist_path, segment_template: segment_template)
        args
      end

      private

      def map_args
        out = []
        out += ['-map', "0:v:#{@params[:video_track] || 0}"]
        out += ['-map', "0:a:#{@params[:audio_track] || 0}?"]
        out
      end

      def video_args
        out = ['-c:v', @params[:video_codec]]
        out += ['-preset', 'veryfast', '-tune', 'zerolatency']
        out += ['-profile:v', 'high', '-level', '4.1', '-pix_fmt', 'yuv420p']
        out += ['-b:v', @params[:video_bitrate].to_s]
        out += ['-maxrate', @params[:video_bitrate].to_s, '-bufsize', (@params[:video_bitrate] * 2).to_s]
        out += keyframe_args
        out += scale_args if @params[:max_height]
        out
      end

      def keyframe_args
        gop = @params[:segment_length] * 24 # rough; full version computes from input fps
        ['-g', gop.to_s, '-keyint_min', gop.to_s, '-sc_threshold', '0',
         '-force_key_frames', "expr:gte(t,n_forced*#{@params[:segment_length]})"]
      end

      def scale_args
        ['-vf', "scale=-2:'min(#{@params[:max_height]},ih)'"]
      end

      def audio_args
        ['-c:a', @params[:audio_codec], '-b:a', @params[:audio_bitrate].to_s, '-ac', '2']
      end

      def hls_args(playlist_path:, segment_template:)
        [
          '-f', 'hls',
          '-hls_time', @params[:segment_length].to_s,
          '-hls_playlist_type', 'event',
          '-hls_flags', 'independent_segments+temp_file',
          '-hls_segment_type', 'mpegts',
          '-hls_segment_filename', segment_template,
          playlist_path
        ]
      end
    end
  end
end
