module Jellyfin
  module Encoding
    module Filters
      # Mirrors EncodingHelper.GetVideoProcessingFilterParam scale segment for
      # software paths. Returns a single `scale=...` filter string or nil if no
      # resize is needed.
      module Scale
        module_function

        def build(job)
          target_w = job.output_width
          target_h = job.output_height
          src_w = job.video_stream&.width
          src_h = job.video_stream&.height

          return nil if target_w.nil? && target_h.nil?
          return nil if src_w.nil? || src_h.nil?

          # If target is at or above source, no-op.
          if target_h && src_h <= target_h && (target_w.nil? || src_w <= target_w)
            return nil
          end

          if target_h && target_w.nil?
            "scale=-2:'min(#{target_h},ih)'"
          elsif target_w && target_h.nil?
            "scale='min(#{target_w},iw)':-2"
          else
            "scale='min(#{target_w},iw)':'min(#{target_h},ih)':force_original_aspect_ratio=decrease"
          end
        end
      end
    end
  end
end
