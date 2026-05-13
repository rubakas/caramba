module Jellyfin
  module Encoding
    # Port of EncodingHelper.EnforceResolutionLimit (cs:2949). Switches the
    # request's `width` + `height` from fixed-value semantics to
    # ceiling/maximum semantics. Used when a client supplies explicit
    # dimensions but we want to honour them as caps instead.
    #
    # Upstream behaviour (verbatim from cs:2953):
    #   - MaxWidth  := MaxWidth  ?? Width
    #   - MaxHeight := MaxHeight ?? Height
    #   - Width  := null
    #   - Height := null
    module ResolutionLimit
      module_function

      # Mutates the job in place. Accepts a Hash (request DTO style) or any
      # object with width / height / max_width / max_height accessors.
      def enforce!(target)
        if target.is_a?(Hash)
          target[:max_width]  ||= target.delete(:width)  || target[:max_width]
          target[:max_height] ||= target.delete(:height) || target[:max_height]
          target[:width]  = nil
          target[:height] = nil
        else
          target.max_width  ||= target.respond_to?(:output_width)  ? target.output_width  : nil
          target.max_height ||= target.respond_to?(:output_height) ? target.output_height : nil
          target.output_width  = nil if target.respond_to?(:output_width=)
          target.output_height = nil if target.respond_to?(:output_height=)
        end
        target
      end
    end
  end
end
