require 'jellyfin/encoding/hwaccel/base'

module Jellyfin
  module Encoding
    module Hwaccel
      # NVIDIA NVENC. Common-path port (~50 LOC upstream).
      module Nvenc
        extend Base
        module_function

        def name = :nvenc

        def available?(caps)
          caps.supports_hwaccel?('cuda') &&
            (caps.supports_encoder?('h264_nvenc') || caps.supports_encoder?('hevc_nvenc'))
        end

        def encoder_for(target_codec, caps)
          case target_codec.to_s.downcase
          when 'h264', 'avc'  then caps.supports_encoder?('h264_nvenc') ? 'h264_nvenc' : nil
          when 'h265', 'hevc' then caps.supports_encoder?('hevc_nvenc') ? 'hevc_nvenc' : nil
          when 'av1'          then caps.supports_encoder?('av1_nvenc')  ? 'av1_nvenc'  : nil
          end
        end

        def decode_args(_job, caps)
          return [] unless caps.supports_hwaccel?('cuda')
          args = ['-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda']
          # Multi-GPU device pin via env var. Upstream reads this from
          # EncodingOptions; we read JELLYFIN_NVENC_GPU since most deployments
          # set this at the process level.
          gpu = ENV['JELLYFIN_NVENC_GPU']
          args.concat(['-hwaccel_device', gpu]) if gpu
          args
        end

        def filter_chain(job, caps)
          chain = []
          # Tonemap with OpenCL fallback when tonemap_cuda is missing — many
          # consumer cards / older driver builds only have OpenCL tonemap.
          if job.hdr_input?
            peak = job.options.tonemapping_peak
            algo = job.options.tonemapping_algorithm
            if caps.supports_filter?('tonemap_cuda')
              chain << "tonemap_cuda=tonemap=#{algo}:peak=#{peak}:format=nv12"
            elsif caps.supports_filter?('tonemap_opencl')
              # CUDA→OpenCL interop bridge.
              chain << 'hwmap=derive_device=opencl,format=opencl'
              chain << "tonemap_opencl=tonemap=#{algo}:peak=#{peak}:format=nv12"
              chain << 'hwmap=derive_device=cuda:reverse=1,format=cuda'
            end
          end
          if job.output_height
            chain << "scale_cuda=-2:'min(#{job.output_height},ih)'"
          end
          chain.empty? ? nil : chain.join(',')
        end

        def encoder_args(job)
          out = ['-preset', preset_for(job), '-tune', 'hq', '-rc', rc_mode_for(job),
                 '-spatial_aq', '1', '-temporal_aq', '1',
                 '-rc-lookahead', job.options.lookahead.to_s,
                 '-b_ref_mode', 'middle']
          # HEVC 10-bit (Main10) path — required for HDR output and higher quality.
          if job.output_video_codec.to_s.downcase.match?(/h265|hevc/) && job.video_stream&.pixel_format.to_s.include?('10')
            out.concat(['-profile:v', 'main10', '-pix_fmt', 'p010le'])
          end
          out
        end

        # NVENC preset p1..p7 — p7 highest quality, slowest. We map upstream
        # symbolic presets to the numeric form used since NVENC SDK 11+.
        def preset_for(job)
          case job.options.encoder_preset.to_s
          when 'ultrafast', 'superfast', 'veryfast' then 'p1'
          when 'faster'                              then 'p2'
          when 'fast'                                then 'p3'
          when 'medium'                              then 'p4'
          when 'slow'                                then 'p5'
          when 'slower'                              then 'p6'
          when 'veryslow', 'placebo'                 then 'p7'
          else                                            'p4'
          end
        end

        def rc_mode_for(job)
          case job.options.rate_control
          when :cbr then 'cbr'
          when :crf then 'vbr' # NVENC's "vbr_hq" is the CRF analog; vbr+spatial_aq comes close
          else           'vbr'
          end
        end
      end
    end
  end
end
