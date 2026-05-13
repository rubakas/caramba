module Jellyfin
  module Rails
    class Configuration
      attr_accessor :ffmpeg_path,
                    :ffprobe_path,
                    :transcode_dir,
                    :token_secret,
                    :allowed_paths,
                    :hwaccel,
                    :idle_timeout,
                    :segment_length,
                    :vaapi_device,
                    :nvenc_gpu,
                    :max_concurrent_transcodes,
                    :fallback_font_path

      def initialize
        @ffmpeg_path              = ENV.fetch('JELLYFIN_FFMPEG', 'ffmpeg')
        @ffprobe_path             = ENV.fetch('JELLYFIN_FFPROBE', 'ffprobe')
        @transcode_dir            = nil # Rails.root.join('tmp/transcodes') resolved lazily
        @token_secret             = ENV.fetch('JELLYFIN_TOKEN_SECRET', nil)
        @allowed_paths            = []
        @hwaccel                  = :none
        @idle_timeout             = 15 * 60
        @segment_length           = 6
        # 0 = unlimited. Production deployments should cap this to roughly the
        # number of physical cores divided by 2 (each ffmpeg eats ~2 cores).
        @max_concurrent_transcodes = ENV.fetch('JELLYFIN_MAX_CONCURRENT_TRANSCODES', 0).to_i
        # Directory of fallback font files served by FallbackFontsController.
        # Mirrors EncodingOptions.FallbackFontPath upstream.
        @fallback_font_path = ENV.fetch('JELLYFIN_FALLBACK_FONT_PATH', nil)
      end

      def resolved_transcode_dir
        @transcode_dir || (defined?(::Rails) && ::Rails.root && ::Rails.root.join('tmp/transcodes')) || '/tmp/jellyfin-rails'
      end

      def path_allowed?(path)
        return false if path.nil? || path.empty?
        real = File.expand_path(path)
        allowed_paths.any? do |base|
          base_real = File.expand_path(base.to_s)
          real == base_real || real.start_with?("#{base_real}/")
        end
      end
    end
  end
end
