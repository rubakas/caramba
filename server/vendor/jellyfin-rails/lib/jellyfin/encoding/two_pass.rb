module Jellyfin
  module Encoding
    # Two-pass encoding orchestration. Pass 1 measures, pass 2 encodes with the
    # measurements as input. Used when the caller wants a tight target bitrate
    # (typical for download / archive use cases) — much better quality at a
    # fixed size than capped-CRF.
    #
    # Two-pass is OFF by default because it doubles encode time, costs more
    # CPU, and HLS playback prefers CRF for adaptive segment sizing. Callers
    # opt in via `EncodingOptions#two_pass = true`.
    #
    # Mirrors EncodingHelper.cs's pass-1/pass-2 split (in upstream this happens
    # when the user has `EncodingOptions.EncodingThreadCount > 0` AND the
    # output is a single-file MP4 download).
    module TwoPass
      module_function

      # Adds `-pass 1 -passlogfile <path>` to a pass-1 invocation.
      def pass1_args(passlog_path)
        ['-pass', '1', '-passlogfile', passlog_path,
         # Pass 1 doesn't need audio encoded.
         '-an',
         # Pass 1 doesn't need any output file beyond null.
         '-f', 'null']
      end

      # Adds `-pass 2 -passlogfile <path>` to a pass-2 invocation.
      def pass2_args(passlog_path)
        ['-pass', '2', '-passlogfile', passlog_path]
      end

      def enabled?(job)
        job.options.respond_to?(:two_pass) && job.options.two_pass
      end

      # Standard naming for the per-job passlog. Two passes share the prefix
      # because ffmpeg appends suffixes like `-0.log` itself.
      def passlog_path(job_dir)
        File.join(job_dir, 'x264-pass')
      end
    end
  end
end
