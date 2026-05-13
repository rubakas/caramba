require 'open3'
require 'json'

module Jellyfin
  module Encoding
    # EBU R128 two-pass loudness normalisation.
    #
    # Pass 1 measures the source's integrated loudness (I), true peak (TP),
    # loudness range (LRA), and threshold. Pass 2 applies a *targeted*
    # normalisation using those measurements — much more accurate than the
    # single-pass `loudnorm=linear=true` we use in `Audio.loudnorm_filter`.
    #
    # Mirrors EncodingHelper.cs's `EnableAudioLoudnessNormalisation` flag,
    # which feeds the per-track measurements into the encoder.
    module LoudnormTwoPass
      Measurement = Struct.new(:input_i, :input_tp, :input_lra, :input_thresh,
                               :target_offset, keyword_init: true) do
        # Renders an ffmpeg-ready `loudnorm` filter string with measured values
        # baked in. ffmpeg's manual recommends this exact form for the apply pass.
        def to_filter(target_i: -23, target_tp: -2, target_lra: 7)
          "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}" \
            ":measured_I=#{input_i}:measured_TP=#{input_tp}" \
            ":measured_LRA=#{input_lra}:measured_thresh=#{input_thresh}" \
            ":offset=#{target_offset}:linear=true:print_format=summary"
        end
      end

      module_function

      # Runs the measurement pass and returns a Measurement. Returns nil if the
      # measurement fails (corrupt audio, ffmpeg missing the loudnorm filter,
      # etc.). The result is cached per (path, mtime, audio stream index).
      def measure(path, audio_index:, ffmpeg_path: default_ffmpeg)
        @cache ||= {}
        key = [path, (File.mtime(path).to_i rescue 0), audio_index]
        return @cache[key] if @cache.key?(key)
        @cache[key] = do_measure(path, audio_index, ffmpeg_path)
      end

      def do_measure(path, audio_index, ffmpeg_path)
        cmd = [ffmpeg_path, '-hide_banner', '-nostats',
               '-i', path,
               '-map', "0:a:#{audio_index}",
               '-af', 'loudnorm=print_format=json',
               '-f', 'null', '-']
        _stdout, stderr, status = Open3.capture3(*cmd)
        return nil unless status.success?

        # ffmpeg writes the JSON block at the END of stderr; find the last `{`
        # and parse from there.
        json_start = stderr.rindex('{')
        return nil unless json_start
        data = JSON.parse(stderr[json_start..])
        Measurement.new(
          input_i:       data['input_i'].to_f,
          input_tp:      data['input_tp'].to_f,
          input_lra:     data['input_lra'].to_f,
          input_thresh:  data['input_thresh'].to_f,
          target_offset: data['target_offset'].to_f
        )
      rescue JSON::ParserError
        nil
      end

      def default_ffmpeg
        Jellyfin::Rails.configuration.ffmpeg_path
      end
    end
  end
end
