module Jellyfin
  module Encoding
    module Filters
      # Subtitle burn-in filter generation. Text subs (srt/ass/ssa/vtt) use the
      # `subtitles` filter; graphical subs (pgs/dvb/dvd) use overlay.
      #
      # Mirrors EncodingHelper.cs GetTextSubtitlesFilter / GetGraphicalSubCanvasSize.
      module SubtitleBurn
        TEXT_CODECS = %w[subrip srt ass ssa webvtt mov_text].freeze
        GRAPHICAL_CODECS = %w[hdmv_pgs_subtitle pgssub dvd_subtitle dvbsub].freeze

        module_function

        def build(job, fonts_dir: nil)
          return nil unless job.burn_subtitles?
          codec = job.subtitle_stream.codec.to_s.downcase

          if TEXT_CODECS.include?(codec)
            text_filter(job, fonts_dir: fonts_dir)
          elsif GRAPHICAL_CODECS.include?(codec)
            graphical_overlay(job)
          else
            nil # unknown — skip
          end
        end

        def text_filter(job, fonts_dir: nil)
          input = ffmpeg_escape(job.media_source.path)
          si = subtitle_si_index(job)
          filter = "subtitles=#{input}:si=#{si}#{charenc(job)}"
          filter += ":fontsdir='#{fonts_dir}'" if fonts_dir
          filter
        end

        def graphical_overlay(job)
          _inputs, chain = Jellyfin::Subtitle::PgsOverlay.build(job)
          chain
        end

        def subtitle_si_index(job)
          # Counting subtitle streams up to (but not including) the chosen one.
          subs = job.media_source.subtitle_streams
          subs.index { |s| s.index == job.subtitle_stream.index } || 0
        end

        def charenc(job)
          # Auto-detect for sidecar subs that aren't UTF-8. Embedded streams in
          # an MKV are already utf-8 normalised by the container, so we only
          # bother for external paths.
          ext_path = job.subtitle_stream.respond_to?(:external_path) && job.subtitle_stream.external_path
          return '' unless ext_path
          name = Jellyfin::Subtitle::Charset.detect(ext_path)
          iconv = Jellyfin::Subtitle::Charset.to_iconv(name)
          iconv ? ":charenc=#{iconv}" : ''
        end

        def ffmpeg_escape(path)
          # The ffmpeg subtitles filter needs special chars escaped twice.
          path.to_s.gsub('\\', '\\\\\\\\').gsub(':', '\\:').gsub("'", "\\\\'")
        end
      end
    end
  end
end
