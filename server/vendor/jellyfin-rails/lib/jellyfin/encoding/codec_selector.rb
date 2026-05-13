module Jellyfin
  module Encoding
    # Ports the GetH264Encoder / GetH265Encoder / GetAv1Encoder / GetAudioEncoder
    # methods from EncodingHelper.cs.
    #
    # Selection order for video:
    #   1. If the caller asked for `copy`, honor that immediately.
    #   2. If `hw_type` is supplied AND the corresponding Hwaccel backend
    #      reports it can encode this codec AND ffmpeg has the HW encoder
    #      compiled in, use it.
    #   3. Fall through to the software ladder, preferring better encoders
    #      (libfdk_aac before stock aac, etc.).
    #
    # Hwaccel backends live in lib/jellyfin/encoding/hwaccel/* and are the
    # source of truth for HW encoder names per platform.
    module CodecSelector
      # Software ladders kept in priority order. The first candidate that
      # ffmpeg supports wins.
      H264_SW_CANDIDATES = %w[libx264].freeze
      H265_SW_CANDIDATES = %w[libx265].freeze
      AV1_SW_CANDIDATES  = %w[libsvtav1 libaom-av1].freeze

      # Hardware encoders per accel family. Keyed by accel type then target
      # codec. The ffmpeg name is looked up in capabilities before being used.
      HW_CANDIDATES = {
        videotoolbox: { 'h264' => 'h264_videotoolbox', 'hevc' => 'hevc_videotoolbox' },
        nvenc:        { 'h264' => 'h264_nvenc',        'hevc' => 'hevc_nvenc',        'av1' => 'av1_nvenc' },
        qsv:          { 'h264' => 'h264_qsv',          'hevc' => 'hevc_qsv',          'av1' => 'av1_qsv' },
        vaapi:        { 'h264' => 'h264_vaapi',        'hevc' => 'hevc_vaapi',        'av1' => 'av1_vaapi' }
      }.freeze

      AUDIO_CANDIDATES = {
        'aac'    => %w[libfdk_aac aac],
        'mp3'    => %w[libmp3lame].freeze,
        'opus'   => %w[libopus].freeze,
        'flac'   => %w[flac].freeze,
        'ac3'    => %w[ac3].freeze,
        'eac3'   => %w[eac3].freeze
      }.freeze

      module_function

      def video_encoder_for(target_codec, capabilities, hw_type: nil)
        # `copy` is honored without consulting capabilities.
        return 'copy' if target_codec == 'copy'

        codec_key =
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then 'h264'
          when 'h265', 'hevc' then 'hevc'
          when 'av1'          then 'av1'
          end

        if hw_type && codec_key
          hw = HW_CANDIDATES.dig(hw_type.to_sym, codec_key)
          return hw if hw && capabilities.respond_to?(:supports_encoder?) && capabilities.supports_encoder?(hw)
        end

        candidates =
          case codec_key
          when 'h264' then H264_SW_CANDIDATES
          when 'hevc' then H265_SW_CANDIDATES
          when 'av1'  then AV1_SW_CANDIDATES
          else             [target_codec.to_s]
          end

        candidates.find { |c| capabilities.supports_encoder?(c) } || candidates.first
      end

      def audio_encoder_for(target_codec, capabilities)
        return 'copy' if target_codec == 'copy'
        candidates = AUDIO_CANDIDATES.fetch(target_codec.to_s.downcase, [target_codec.to_s])
        candidates.find { |c| capabilities.supports_encoder?(c) } || candidates.first
      end

      # Mirrors the CanStreamCopyVideo logic — gating direct stream when output
      # constraints are compatible with the source. Phase 5 covers the common
      # cases; full implementation has dozens of edge cases (profile, level,
      # GOP size, bitrate caps, anamorphic, DLNA constraints).
      def can_stream_copy_video?(job)
        return false unless job.video_stream
        return true  if job.output_video_codec == 'copy'

        in_codec  = job.video_stream.codec.to_s.downcase
        out_codec = job.output_video_codec.to_s.downcase
        return false unless codec_matches?(in_codec, out_codec)
        return false if job.output_height && job.video_stream.height && job.video_stream.height > job.output_height
        return false if job.output_video_bitrate && job.video_stream.bit_rate && job.video_stream.bit_rate > job.output_video_bitrate * 1.1
        true
      end

      def can_stream_copy_audio?(job)
        return false unless job.audio_stream
        return true  if job.output_audio_codec == 'copy'

        in_codec  = job.audio_stream.codec.to_s.downcase
        out_codec = job.output_audio_codec.to_s.downcase
        return false unless codec_matches?(in_codec, out_codec)
        return false if job.output_audio_channels && job.audio_stream.channels && job.audio_stream.channels > job.output_audio_channels
        true
      end

      def codec_matches?(a, b)
        return true if a == b
        equivalent = { 'h264' => %w[h264 avc], 'h265' => %w[h265 hevc] }
        equivalent.any? { |_k, group| group.include?(a) && group.include?(b) }
      end
    end
  end
end
