module Jellyfin
  module Encoding
    # Optional frame-rate interpolation (motion-compensated). Useful when the
    # source is a low-fps animation or surveillance recording and the client
    # asks for a smoother playback rate.
    #
    # We use `minterpolate=fps=N:mi_mode=mci` — motion-compensated interpolation
    # produces visibly smoother results than `fps=N` (which just duplicates
    # frames) but costs significant CPU. Off by default.
    module FrameInterp
      module_function

      def build(job)
        opts = job.options
        return nil unless opts.respond_to?(:frame_interpolation) && opts.frame_interpolation
        target = opts.respond_to?(:target_framerate) && opts.target_framerate
        return nil unless target
        source = job.video_stream&.frame_rate.to_f
        # Only interpolate UP — never down-rate via minterpolate (slower than fps=).
        return nil if source.zero? || source >= target
        "minterpolate=fps=#{target}:mi_mode=mci"
      end
    end
  end
end
