module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetProgressiveAudioFullCommandLine (cs:7763).
    # Audio-only progressive transcode for /Audio/{id}/stream.{container}.
    module ProgressiveAudio
      LOSSLESS_CODECS = %w[flac alac wav pcm pcm_s16le pcm_s24le].freeze

      # Opus only supports the standardised sample rates; upstream coerces
      # arbitrary rates onto these tiers (cs:7806).
      OPUS_RATE_TIERS = [8_000, 12_000, 16_000, 24_000, 48_000].freeze

      module_function

      def command_line(job:, output_path:, capabilities:)
        helper          = Jellyfin::Encoding::EncodingHelper.new(capabilities)
        input_args_list, _cleanup = Jellyfin::Encoding::InputSource.build(job)
        encoder         = Jellyfin::Encoding::CodecSelector.audio_encoder_for(job.output_audio_codec, capabilities)
        bitrate         = job.output_audio_bitrate
        channels        = job.output_audio_channels
        out_codec       = job.output_audio_codec.to_s.downcase

        args  = []
        args += helper.send(:global_args)
        args += helper.send(:probe_args, job)
        args += input_args_list
        args += ['-vn']
        # Bitrate flag is skipped for lossless codecs (upstream cs:7771).
        if bitrate && !LOSSLESS_CODECS.include?(out_codec)
          args += ['-ab', bitrate.to_s]
        end
        args += ['-ac', channels.to_s] if channels
        args += ['-acodec', encoder] if encoder && !encoder.empty?
        # PCM family: encode + raw container in one move (cs:7794).
        if encoder.to_s.start_with?('pcm_')
          args += ['-f', encoder.sub(/^pcm_/, '')]
          args += ['-ar', bitrate.to_s] if bitrate # upstream uses BaseRequest.AudioBitRate here as the sample rate
        end
        # Sample-rate quantisation for non-opus codecs.
        if out_codec != 'opus' && job.output_audio_sample_rate
          args += ['-ar', quantize_rate(job.output_audio_sample_rate).to_s]
        end
        # MP4-family containers need the same movflags as progressive video
        # to allow streaming playback (cs:7821).
        if mp4_container?(job)
          args += ['-movflags', 'empty_moov+delay_moov']
        end
        # ID3 tagging — upstream emits these unconditionally for non-PCM.
        args += ['-id3v2_version', '3', '-write_id3v1', '1'] unless encoder.to_s.start_with?('pcm_')
        args += ['-y', output_path]
        args
      end

      def quantize_rate(rate)
        return rate if OPUS_RATE_TIERS.last.zero?
        OPUS_RATE_TIERS.find { |t| rate.to_i <= t } || OPUS_RATE_TIERS.last
      end

      MP4_CONTAINERS = %w[mp4 m4a m4b aac mov].freeze

      def mp4_container?(job)
        container = job.options.respond_to?(:output_container) ? job.options.output_container : nil
        return false unless container
        MP4_CONTAINERS.include?(container.to_s.downcase)
      end
    end
  end
end
