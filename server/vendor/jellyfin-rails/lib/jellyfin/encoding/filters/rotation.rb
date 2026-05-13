module Jellyfin
  module Encoding
    module Filters
      # Container-level rotation metadata fixup. When a phone records video in
      # portrait mode the bitstream is still recorded as 1920x1080 landscape but
      # carries a Display-Matrix or `tags.rotate` instructing players to rotate
      # the image 90°/180°/270° before display. Players that obey this tag look
      # fine. Players that don't (and many fixed-function decoders) show the
      # video sideways. ffmpeg honours the metadata only when transcoding, NOT
      # when re-muxing or stream-copying, so we have to bake the rotation in.
      #
      # The mapping below produces an `-vf` fragment that physically rotates
      # pixels and clears the rotation metadata so downstream players don't
      # rotate again. Mirrors EncodingHelper.cs `GetVideoFilterParam` rotation
      # path (search for `transpose`).
      module Rotation
        module_function

        # Returns nil when no rotation is needed. The filter argument is
        # composed of one or two ffmpeg `transpose` invocations.
        def build(job)
          rot = job.video_stream&.rotation.to_i
          return nil if rot.zero?
          # Normalise to 0/90/180/270 — the probe normaliser already does this
          # but be defensive.
          rot = ((rot % 360) + 360) % 360
          case rot
          when 90  then 'transpose=1'              # 90° clockwise
          when 180 then 'transpose=1,transpose=1'   # 180°
          when 270 then 'transpose=2'              # 90° counter-clockwise
          end
        end

        # Side-band ffmpeg args to clear the rotation metadata from the OUTPUT
        # container after the rotation is baked in. Without this, MP4/MKV
        # players that obey the tag would rotate the already-rotated pixels
        # a second time, showing the video sideways again.
        def metadata_args(job)
          return [] if job.video_stream&.rotation.to_i.zero?
          ['-metadata:s:v:0', 'rotate=0']
        end
      end
    end
  end
end
