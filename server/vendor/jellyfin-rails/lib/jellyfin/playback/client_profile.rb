module Jellyfin
  module Playback
    # Describes what a client device can decode without help. Mirrors the slice
    # of MediaBrowser.Model.Dlna.DeviceProfile that the direct-play decision
    # actually reads — codecs, containers, profiles, levels, bitrate cap.
    #
    # Hosts pass one in via the player helper or the controller; sensible
    # defaults exist for the common cases (modern web browsers).
    class ClientProfile
      attr_accessor :containers,            # %w[mp4 mkv webm] etc.
                    :video_codecs,          # %w[h264 hevc av1 vp9]
                    :audio_codecs,          # %w[aac mp3 opus ac3 eac3]
                    :max_video_bitrate,     # bits/sec, nil = unlimited
                    :max_audio_channels,    # 2, 6, 8, ...
                    :max_video_height,
                    :max_video_width,
                    :max_video_fps,
                    :h264_profiles,         # %w[baseline main high high10]
                    :h264_level,            # 41, 51, 52
                    :hevc_profiles,         # %w[main main10]
                    :hevc_level,
                    :max_video_b_frames,    # int, nil = unbounded
                    :max_audio_bit_depth,   # 16, 24, ...; nil = unbounded
                    :supports_hdr,
                    :supports_dovi,
                    :supports_10bit,
                    :supports_anamorphic,
                    :supports_interlaced,
                    :supports_open_gop

      def self.modern_browser
        new.tap do |p|
          p.containers          = %w[mp4 m4v mov webm]
          p.video_codecs        = %w[h264 vp9 av1]
          p.audio_codecs        = %w[aac mp3 opus]
          p.max_video_bitrate   = 20_000_000
          p.max_audio_channels  = 6
          p.max_video_height    = 1080
          p.max_video_width     = 1920
          p.max_video_fps       = 60
          p.h264_profiles       = %w[baseline main high]
          p.h264_level          = 41
          p.hevc_profiles       = []
          p.hevc_level          = nil
          p.max_video_b_frames  = 3   # browsers reliably handle 3, often choke past 4
          p.max_audio_bit_depth = 16
          p.supports_hdr        = false
          p.supports_dovi       = false
          p.supports_10bit      = false
          p.supports_anamorphic = false
          p.supports_interlaced = false
          p.supports_open_gop   = false
        end
      end

      def self.safari
        modern_browser.tap do |p|
          p.containers   = %w[mp4 m4v mov]
          p.video_codecs = %w[h264 hevc]
          p.audio_codecs = %w[aac mp3]
          p.hevc_profiles = %w[main main10]
          p.hevc_level = 51
          p.supports_hdr = true
          p.supports_10bit = true
        end
      end

      def self.appletv_4k
        new.tap do |p|
          p.containers          = %w[mp4 m4v mov hls]
          p.video_codecs        = %w[h264 hevc]
          p.audio_codecs        = %w[aac ac3 eac3]
          p.max_video_bitrate   = 50_000_000
          p.max_audio_channels  = 8
          p.max_video_height    = 2160
          p.max_video_width     = 3840
          p.max_video_fps       = 60
          p.h264_profiles       = %w[baseline main high]
          p.h264_level          = 51
          p.hevc_profiles       = %w[main main10]
          p.hevc_level          = 52
          p.max_video_b_frames  = 4
          p.max_audio_bit_depth = 24
          p.supports_hdr        = true
          p.supports_dovi       = true
          p.supports_10bit      = true
          p.supports_anamorphic = false
          p.supports_interlaced = false
          p.supports_open_gop   = true
        end
      end

      def to_h
        instance_variables.each_with_object({}) { |k, h| h[k.to_s.delete('@').to_sym] = instance_variable_get(k) }
      end
    end
  end
end
