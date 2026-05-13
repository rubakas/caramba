module Jellyfin
  module Encoding
    # Port of EncodingHelper.GetInputArgument (cs:1236). Builds the unified
    # input portion of an ffmpeg command line including:
    #
    #   - attachment streams (MKV embedded fonts, used by ASS subtitle burn)
    #   - secondary subtitle input (for external sidecar subtitles)
    #   - DRM init segments (Widevine PSSH for CMAF)
    #   - the primary `-i` input
    #
    # Upstream's signature also threads through hwaccel device + segment
    # container choice. We accept them as keyword args.
    module InputArgument
      module_function

      def call(job:, encoding_options: nil, segment_container: nil)
        encoding_options ||= job.options
        args = []

        # 1. Primary input (Encoding::InputSource handles file / http / rtsp /
        # concat). We splat the args here so they appear BEFORE any auxiliary
        # input. When `encoding_options.input_files` is set with multiple
        # paths (port of MediaEncoder.GetInputArgument(IReadOnlyList<string>,
        # MediaSourceInfo) cs:471 — DVD VOB sets, Blu-ray M2TS groups, split
        # MKV), build a concat-protocol input instead.
        if encoding_options.respond_to?(:input_files) && encoding_options.input_files.is_a?(Array) && encoding_options.input_files.size > 1
          args.concat(build_multi_file_input(encoding_options.input_files))
        else
          primary, _cleanup = Jellyfin::Encoding::InputSource.build(job)
          args.concat(primary)
        end

        # 2. Attachment streams. When a subtitle filter needs MKV-embedded
        # fonts, upstream emits `-attach <font> -metadata:s:t mimetype=...`
        # for each font. We delegate to AttachmentExtractor which has already
        # extracted fonts to a cache dir; ffmpeg picks them up via the
        # `fontsdir=` filter option instead, so this branch is intentionally
        # empty unless a future code path needs explicit attachment muxing.

        # 3. External subtitle sidecar. When the chosen subtitle stream is an
        # external file (e.g., movie.eng.srt next to movie.mkv), ffmpeg needs
        # a second `-i` pointing at the sidecar. Subtitle index becomes
        # `0:s:0` on the sidecar input rather than the main one.
        ext = job.subtitle_stream && job.subtitle_stream.respond_to?(:external_path) && job.subtitle_stream.external_path
        if ext
          args.concat(['-i', ext.to_s])
        end

        # 4. DRM init segment. When the output is CMAF + encrypted, ffmpeg's
        # mp4 muxer reads an init segment for `-init_seg_name`. We surface
        # this through EncodingOptions#cmaf_init_segment_path when set.
        if encoding_options.respond_to?(:cmaf_init_segment_path) && encoding_options.cmaf_init_segment_path
          args.concat(['-i', encoding_options.cmaf_init_segment_path])
        end

        args
      end

      # Mirrors MediaEncoder.GetInputArgument(IReadOnlyList<string>,
      # MediaSourceInfo). Concat-protocol input lets ffmpeg treat a list of
      # files (DVD VOB sets, multi-part MKVs) as a single virtual stream.
      def build_multi_file_input(files)
        # Use ffmpeg's `concat:` URL form for single-codec streams (mpegts /
        # h264 / mpeg2) which DVD VOB sets use. For mixed-codec multi-part
        # sources the demuxer concat (`-f concat -i list.txt`) is better,
        # but the URL form is universally supported and what upstream uses
        # for this overload.
        joined = files.map(&:to_s).join('|')
        ['-i', "concat:#{joined}"]
      end
    end
  end
end
