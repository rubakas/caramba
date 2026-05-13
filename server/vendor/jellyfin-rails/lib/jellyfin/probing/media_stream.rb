module Jellyfin
  module Probing
    # POD model for a single media stream — mirrors the subset of MediaBrowser.Model.Entities.MediaStream
    # that downstream code (EncodingHelper, controller serialization) actually reads.
    class MediaStream
      ATTRS = %i[
        index type codec codec_tag profile level
        bit_rate channels sample_rate bit_depth
        width height pixel_format display_aspect_ratio sample_aspect_ratio
        frame_rate avg_frame_rate is_vfr
        is_default is_forced is_external language title
        is_avc nal_length_size refs has_b_frames
        color_range color_space color_transfer color_primaries
        video_range video_range_type
        max_cll max_fall mastering_display
        dovi_profile dovi_rpu_present dovi_bl_present dovi_el_present
        field_order is_interlaced
        gop_size gop_closed
        channel_layout codec_long_name
        external_path
        rotation
        hdr10plus_present
        closed_captions
        has_closed_captions
      ].freeze

      attr_accessor(*ATTRS)

      def initialize(**attrs)
        ATTRS.each { |k| instance_variable_set(:"@#{k}", attrs[k]) }
      end

      def video?    = type == :video
      def audio?    = type == :audio
      def subtitle? = type == :subtitle

      def hdr?
        return false unless video?
        %w[hdr10 hdr10plus dovi dolbyvision hlg].include?(video_range_type.to_s.downcase)
      end

      def ten_bit?
        bit_depth.to_i == 10 || pixel_format.to_s.include?('10')
      end

      def twelve_bit?
        bit_depth.to_i == 12 || pixel_format.to_s.include?('12')
      end

      def anamorphic?
        sar = sample_aspect_ratio.to_s
        !sar.empty? && sar != '1:1' && sar != '0:1'
      end

      def to_h
        ATTRS.each_with_object({}) { |k, h| h[k] = public_send(k) }
      end
    end
  end
end
