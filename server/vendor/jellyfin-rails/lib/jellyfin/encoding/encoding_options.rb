module Jellyfin
  module Encoding
    # Mirrors MediaBrowser.Model.Configuration.EncodingOptions — the slice
    # EncodingHelper actually reads.
    class EncodingOptions
      attr_accessor :hardware_acceleration_type,
                    :encoder_preset,
                    :rate_control,          # :crf, :vbr, :cbr — default :crf for VOD
                    :h264_crf,
                    :h265_crf,
                    :av1_crf,
                    :b_frames,
                    :ref_frames,
                    :lookahead,
                    :throttle_seconds,
                    :throttle_delay_seconds,
                    :allow_h264_encoding,
                    :allow_h265_encoding,
                    :allow_av1_encoding,
                    :enable_hardware_encoding,
                    :prefer_system_native_hw_decoder,
                    :enable_subtitle_extraction,
                    :enable_tonemapping,
                    :tonemapping_algorithm,
                    :tonemapping_peak,
                    :downmix_audio_boost,
                    :enable_drc,
                    :enable_loudnorm,
                    :audio_itsoffset_seconds,
                    :force_accurate_seek,
                    :x264_tune,
                    :dovi_rpu_path,
                    :auto_crop,
                    :two_pass,
                    :frame_interpolation,
                    :target_framerate,
                    :multi_audio_tracks,
                    :http_user_agent,
                    :http_headers,
                    :concat_parts,
                    :hls_encryption_material,
                    :tonemapping_range,
                    :encoder_app_path,
                    :deinterlace_method,    # :yadif, :bwdif, :off
                    :preserve_hdr_metadata, # passes through color_primaries/transfer/space
                    :vaapi_device           # /dev/dri/renderDxx override

      def initialize
        @hardware_acceleration_type = :none
        @encoder_preset = 'veryfast'
        @rate_control = :crf
        @h264_crf = 23
        @h265_crf = 28
        @av1_crf = 30
        @b_frames = 3
        @ref_frames = 3
        @lookahead = 20
        @throttle_seconds = 180        # buffer ahead of player by this many seconds
        @throttle_delay_seconds = 5    # poll interval for throttler
        @allow_h264_encoding = true
        @allow_h265_encoding = true
        @allow_av1_encoding = false
        @enable_hardware_encoding = false
        @prefer_system_native_hw_decoder = false
        @enable_subtitle_extraction = true
        @enable_tonemapping = true
        @tonemapping_algorithm = 'bt2390'
        @tonemapping_peak = 100
        @downmix_audio_boost = 2.0
        @enable_drc = false
        @enable_loudnorm = false
        @audio_itsoffset_seconds = 0.0
        @force_accurate_seek = false
        @x264_tune = nil
        @dovi_rpu_path = nil
        @auto_crop = false
        @two_pass = false
        @frame_interpolation = false
        @target_framerate = nil
        @multi_audio_tracks = false
        @http_user_agent = nil
        @http_headers = nil
        @concat_parts = nil
        @hls_encryption_material = nil
        @deinterlace_method = :yadif
        @preserve_hdr_metadata = true
      end

      def hardware_acceleration?
        enable_hardware_encoding && hardware_acceleration_type != :none
      end
    end
  end
end
