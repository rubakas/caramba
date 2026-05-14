require 'jellyfin/encoding/encoding_job_info'
require 'jellyfin/encoding/codec_selector'
require 'jellyfin/encoding/bitrate'
require 'jellyfin/encoding/filters/scale'
require 'jellyfin/encoding/filters/tonemap'
require 'jellyfin/encoding/filters/subtitle_burn'
require 'jellyfin/encoding/filters/deinterlace'
require 'jellyfin/encoding/filters/anamorphic'
require 'jellyfin/encoding/hwaccel'
require 'jellyfin/encoding/stream_copy'
require 'jellyfin/encoding/framerate'
require 'jellyfin/encoding/profile_mapping'
require 'jellyfin/encoding/audio'
require 'jellyfin/encoding/seek'
require 'jellyfin/encoding/quality'
require 'jellyfin/encoding/dolby_vision'
require 'jellyfin/encoding/bitstream_filters'

module Jellyfin
  module Encoding
    # Ruby port of MediaBrowser.Controller.MediaEncoding.EncodingHelper (7,905 LOC C#).
    # Phase 5: software paths only. Hardware acceleration branches arrive in phase 6.
    #
    # Public entry point: `EncodingHelper.command_line_arguments(job, playlist_path:, segment_template:)`.
    # The job is an EncodingJobInfo carrying input MediaSourceInfo + output targets.
    class EncodingHelper
      def self.command_line_arguments(job, playlist_path:, segment_template:, capabilities:, start_segment: 0)
        new(capabilities).command_line_arguments(job, playlist_path: playlist_path,
                                                      segment_template: segment_template,
                                                      start_segment: start_segment)
      end

      def initialize(capabilities)
        @caps = capabilities
      end

      def command_line_arguments(job, playlist_path:, segment_template:, start_segment: 0)
        backend = resolve_hwaccel(job)
        plan = Seek.plan_for(job, start_segment: start_segment)
        input_args_list, _cleanup = InputSource.build(job)

        args = []
        args += global_args
        args += probe_args(job)             # -probesize/-analyzeduration tuned per source
        args += dovi_input_args(job)        # `-strict unofficial` before ffmpeg sees DV NALs
        args += backend ? backend.decode_args(job, @caps) : []
        args += plan.pre_input              # FAST seek (jump on keyframe before decode)
        args += input_args_list             # handles file / http / concat / stream
        args += plan.post_input             # ACCURATE seek (decode+discard after input)
        args += map_args(job)
        args += video_args(job, backend: backend)
        args += audio_args(job)
        args += Filters::Rotation.metadata_args(job)
        args += hls_output_args(job, playlist_path: playlist_path, segment_template: segment_template)
        args += Seek.hls_segment_number_args(plan.start_segment)
        args
      end

      def resolve_hwaccel(job)
        return nil unless job.hw_accel?
        backend = Hwaccel.for(job.options.hardware_acceleration_type)
        return nil unless backend && backend.available?(@caps)
        # Mirror upstream EncodingHelper.cs:333 IsVideoToolboxFullSupported:
        # if the backend would need SW tonemap (HDR input + no HW tonemap
        # filter), refuse the HW path entirely. Mixing SW-filter output
        # (system-memory yuv420p) with a HW encoder fails format
        # negotiation in ffmpeg. Falls back to all-SW (libx264 + tonemapx).
        return nil if job.hdr_input? && !backend.full_chain_supported?(@caps)
        backend
      end

      # --- segments ---

      def global_args
        [ '-hide_banner', '-loglevel', 'warning', '-y', '-fflags', '+genpts' ]
      end

      # Per-source probe budget tuning. Goes BEFORE the `-i` flag so ffmpeg
      # uses the budget while opening the input.
      def probe_args(job)
        ProbeTuning.input_args(job)
      end

      # Retained for backwards-compatible callers; same semantics as the
      # original pre-input fast seek.
      def seek_args(job)
        Seek.plan_for(job).pre_input
      end

      def input_args(job)
        [ '-i', job.media_source.path ]
      end

      def map_args(job)
        out = []
        out += [ '-map', "0:v:#{video_index(job)}" ]
        out += [ '-map', "0:a:#{audio_index(job)}?" ]
        out
      end

      def video_args(job, backend: nil)
        # Stream-copy short-circuit. Upstream EncodingHelper.cs:1009 checks
        # GetVideoEncoder == "copy" the same way; keep it first so neither
        # the backend nor CodecSelector has to deal with the copy case.
        return [ '-c:v', 'copy' ] if job.stream_copy_video? || job.output_video_codec.to_s == 'copy'

        # Hwaccel backends accept the codec FAMILY (h264 / hevc / av1) and
        # return the platform-specific encoder name (h264_videotoolbox etc).
        # Mirrors upstream EncodingHelper.GetH26xOrAv1Encoder(defaultEncoder,
        # hwEncoder, ...) where hwEncoder is the family — see
        # MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs:210.
        # Previously this passed `job.output_video_codec` (defaults to
        # 'libx264'), which no backend's case-match recognises — every
        # transcode silently fell through to software, pegging the CPU.
        codec_family = job.actual_output_video_codec
        hw_encoder = backend&.encoder_for(codec_family, @caps)
        # Only pass hw_type to CodecSelector when the backend resolver
        # already approved the HW path. If resolve_hwaccel declined
        # (e.g. HDR source on a build without tonemap_videotoolbox), the
        # caller wants all-SW; passing hw_type would let CodecSelector
        # pick h264_videotoolbox via its fallback table and reintroduce
        # the mixed SW-filter / HW-encoder bug.
        encoder = hw_encoder || CodecSelector.video_encoder_for(
          codec_family || job.output_video_codec,
          @caps,
          hw_type: backend ? job.options.hardware_acceleration_type : nil
        )

        out = [ '-c:v', encoder ]
        out += backend ? backend.encoder_args(job) : quality_args(job, encoder)
        out += rate_control_args(job)
        # h264 mainstream is 8-bit; h264_videotoolbox + libx264 both need
        # 8-bit input. The "HW encoder picks its own format" intent was
        # right for 8-bit→8-bit pivots, but with a 10-bit source (HEVC
        # Main 10, the dominant rip format today) ffmpeg hands the HW
        # encoder a 10-bit `yuv420p10le` frame, h264_videotoolbox
        # refuses to consume it, and `-allow_sw 1` silently falls back
        # to libx264 — at ~1× realtime, multi-threaded, with the user
        # seeing `190% CPU` in `ps`. Forcing `-pix_fmt yuv420p` makes
        # ffmpeg auto-insert the 10→8 conversion ahead of the encoder,
        # so the HW pipeline stays on h264_videotoolbox at ~6× realtime
        # (verified on the user's `Office S01E03` HEVC 10-bit MKV).
        # Skip only when target codec is one where 10-bit is the
        # ordinary output (h265/hevc, av1) — they pick a matching
        # pixel format themselves.
        out += pixel_format_args(job) unless allows_10bit_output?(job.output_video_codec)
        out += keyframe_args(job)
        out += hdr_passthrough_args(job)

        chain = backend&.filter_chain(job, @caps) || filter_chain(job)
        # When HW overlay is available, replace the SW overlay leg of the chain
        # with the accel-specific filter to keep the pipeline on the GPU.
        if backend && (hw_overlay = Filters::HwSubtitleOverlay.build(job, backend.name))
          # `Filters::SubtitleBurn.build` is what filter_chain produces for the
          # graphical-sub case. Swap it for the HW variant in the final chain.
          chain = chain.sub(/\[v\]\[s\]overlay[^,]*|\[v\]\[s\]overlay[^,]*/, hw_overlay) if chain
          chain = "#{chain},#{hw_overlay}" unless chain.to_s.include?(hw_overlay)
        end
        out += [ '-vf', chain ] unless chain.nil? || chain.empty?
        out
      end

      def quality_args(job, encoder)
        out = Quality.for(job, encoder)
        # Level is only emitted for H.264/H.265 — AV1 etc derive theirs.
        if %w[libx264 libx265].include?(encoder.to_s)
          family = encoder.to_s == 'libx264' ? 'h264' : 'h265'
          # Insert -level right after -preset (the established slot in the existing test fixtures).
          insert_at = out.index('-preset')
          if insert_at
            out = out.dup
            out.insert(insert_at + 2, '-level', level_for(job, family))
          end
        end
        out
      end

      # Rate control. Default to CRF for VOD (variable bitrate, constant quality),
      # fall back to capped-CRF (CRF + maxrate) when a bitrate ceiling is set.
      # Pure CBR/VBR only when explicitly requested.
      def rate_control_args(job)
        opts = job.options

        case opts.rate_control
        when :crf
          crf = crf_for(job)
          # When the caller passes a bitrate, treat it as a ceiling (capped CRF).
          if job.output_video_bitrate
            b = Bitrate.video_bitrate_for(job)
            [ '-crf', crf.to_s, '-maxrate', b.to_s, '-bufsize', (b * 2).to_s ]
          else
            [ '-crf', crf.to_s ]
          end
        when :vbr
          b = Bitrate.video_bitrate_for(job)
          [ '-b:v', b.to_s, '-maxrate', (b * 1.5).to_i.to_s, '-bufsize', (b * 2).to_s ]
        when :cbr
          b = Bitrate.video_bitrate_for(job)
          [ '-b:v', b.to_s, '-maxrate', b.to_s, '-bufsize', (b * 2).to_s, '-minrate', b.to_s ]
        else
          b = Bitrate.video_bitrate_for(job)
          [ '-b:v', b.to_s ]
        end
      end

      def crf_for(job)
        case job.output_video_codec.to_s.downcase
        when 'h265', 'hevc', 'libx265' then job.options.h265_crf
        when 'av1', 'libsvtav1', 'libaom-av1' then job.options.av1_crf
        else                            job.options.h264_crf
        end
      end

      # Approximate H.264/H.265 level from output resolution × framerate.
      # Mirrors NormalizeTranscodingLevel — picks the lowest level that fits.
      # H.264/H.265 level normalization. Picks the lowest level that satisfies
      # the macroblock-per-second budget for the chosen profile. Mirrors the
      # NormalizeTranscodingLevel decision tree from EncodingHelper.cs.
      def level_for(job, family)
        w = job.output_width  || job.video_stream&.width  || 1920
        h = job.output_height || job.video_stream&.height || 1080
        fps = (job.video_stream&.frame_rate || 30).round
        mbps = (w * h * fps) / (16.0 * 16.0)

        if family == 'h264'
          # H.264 Annex A.3.2 — pick the lowest level whose MB/s budget fits.
          # Upstream Jellyfin promotes 1080p30 to 4.1 (vs spec-min 4.0) for
          # bitrate-cap headroom on streaming clients, so we do the same.
          return '3.0' if mbps <=  40_500
          return '3.1' if mbps <= 108_000
          return '3.2' if mbps <= 216_000
          return '4.1' if mbps <= 245_760   # includes spec-4.0; promoted to 4.1
          return '4.2' if mbps <= 522_240
          return '5.0' if mbps <= 589_824
          return '5.1' if mbps <= 983_040
          '5.2'
        else # h265
          pixels = w * h
          return '3.0' if pixels <= 1280 * 720  && fps <= 30
          return '3.1' if pixels <= 1280 * 720  && fps <= 60
          return '4.0' if pixels <= 1920 * 1080 && fps <= 30
          return '4.1' if pixels <= 1920 * 1080 && fps <= 60
          return '5.0' if pixels <= 3840 * 2160 && fps <= 30
          '5.1'
        end
      end

      def pixel_format_args(_job)
        [ '-pix_fmt', 'yuv420p' ]
      end

      # True for output codecs whose ordinary deployment is 10-bit and
      # which pick a matching pixel format on their own. Used to gate
      # `-pix_fmt yuv420p` so we don't force-downconvert 10-bit-native
      # output. h264/AVC mainstream is 8-bit only (Hi10P is a niche
      # profile most decoders refuse), so the cap applies to it; h265
      # and av1 carry 10-bit natively.
      def allows_10bit_output?(output_codec)
        %w[hevc h265 hevc_videotoolbox hevc_nvenc hevc_qsv hevc_amf
           av1 av01 libsvtav1 libaom-av1 av1_nvenc av1_qsv av1_amf]
          .include?(output_codec.to_s.downcase)
      end

      def keyframe_args(job)
        fps = (job.video_stream&.frame_rate || 24).round
        gop = (job.segment_length * fps).clamp(24, 480)
        [ '-g', gop.to_s, '-keyint_min', gop.to_s, '-sc_threshold', '0',
         '-force_key_frames', "expr:gte(t,n_forced*#{job.segment_length})" ]
      end

      def filter_chain(job)
        chain = []
        # Order matters: deinterlace first (works on raw fields), then crop
        # (so subsequent filters see correct dimensions), then rotation, then
        # scale, then colour/HDR transforms, then anamorphic correction, then
        # subtitle burn-in last (subs should be ON TOP of everything else).
        chain << Filters::Deinterlace.build(job)
        chain << Filters::CropDetect.build(job)
        chain << Filters::Rotation.build(job)
        chain << FrameInterp.build(job)
        chain << Filters::Scale.build(job)
        chain << ColorMatrix.build(job)
        chain << Filters::Tonemap.build(job, @caps)
        chain << Filters::Anamorphic.build(job)
        chain << Filters::SubtitleBurn.build(job)
        chain.compact.join(',')
      end

      # HDR metadata passthrough flags. Only meaningful when we're NOT tone-
      # mapping (i.e., output is also HDR); the tonemap chain produces SDR and
      # rewrites color tags anyway, so emitting these would lie about the output.
      def hdr_passthrough_args(job)
        return [] unless job.options.preserve_hdr_metadata
        return [] unless job.video_stream&.hdr?
        return [] if tonemap_active?(job)
        v = job.video_stream
        args = []
        args.concat([ '-color_primaries', v.color_primaries ]) if v.color_primaries
        args.concat([ '-color_trc',       v.color_transfer ])  if v.color_transfer
        args.concat([ '-colorspace',      v.color_space ])     if v.color_space
        args.concat(DolbyVision.output_args(v)) if DolbyVision.present?(v)
        args
      end

      # Pre-input args for DV: `-strict unofficial` lets ffmpeg accept DV
      # NAL unit types. Required for both copy and re-encode pipelines.
      def dovi_input_args(job)
        return [] unless DolbyVision.present?(job.video_stream)
        DolbyVision.passthrough_input_args
      end

      def tonemap_active?(job)
        return false unless job.hdr_input?
        job.options.enable_tonemapping
      end

      def audio_args(job)
        encoder = CodecSelector.audio_encoder_for(job.output_audio_codec, @caps)
        return [ '-c:a', 'copy' ] if encoder == 'copy' || job.stream_copy_audio?

        b = Bitrate.audio_bitrate_for(job)
        ch = Bitrate.audio_channels_for(job)
        layout = Audio.channel_layout_for(ch)

        single_track = [ '-c:a', encoder, '-b:a', b.to_s, '-ac', ch.to_s,
                        '-ar', job.output_audio_sample_rate.to_s ]
        single_track.concat([ '-channel_layout', layout ]) if layout
        single_track.concat(Audio.filter_args(job, capabilities: @caps))

        if MultiAudio.enabled?(job)
          # Multi-track output: emit per-stream maps + per-stream codec params
          # and drop the singular `-map 0:a:N?` already added by map_args.
          MultiAudio.args(job, single_track_args: single_track)
        else
          single_track
        end
      end

      # itsoffset must be emitted *before* the audio input. Most jobs use a
      # single combined input, so we attach it via -itsoffset prefixing the
      # input. Callers that want to shift the audio call this and splice it
      # in before `-i`.
      def audio_input_offset_args(job)
        Audio.itsoffset_args(job.options.audio_itsoffset_seconds)
      end

      # Timestamp normalization for HLS output.
      #
      # Stream-copy path: source PTS is preserved end-to-end through `-c:v
      # copy`. The MPEG-TS muxer would otherwise add a 1.4s VBV pre-roll
      # → segment 0 contains samples at `[1.4..7.4s]` while #EXTINF says
      # `[0..6s]` → Safari's currentTime locks at 0. The five-flag combo
      # (`-copyts -avoid_negative_ts disabled -start_at_zero -muxdelay 0
      # -muxpreload 0`) is the Safari-native-HLS recipe — see
      # `project_safari_native_hls_recipe` memory.
      #
      # Full-transcode path: the encoder produces fresh frames, so we
      # MUST NOT pass `-copyts -avoid_negative_ts disabled`. Why:
      # `h264_videotoolbox` (the macOS HW encoder Caramba picks) emits
      # negative DTS for the first few frames because of encoder
      # lookahead. With `-avoid_negative_ts disabled`, those negative
      # DTS pass through into the MPEG-TS muxer, which uses a 33-bit
      # unsigned timestamp field — negative values wrap to ~95443s.
      # Safari sees segment 0 with DTS ≈ 95443s, decides the source is
      # broken, and surfaces MEDIA_ERR_SRC_NOT_SUPPORTED. Upstream
      # Jellyfin's `-copyts -avoid_negative_ts disabled` template only
      # works there because libx264 doesn't emit negative DTS at
      # startup; the hardware path needs the default `make_zero`
      # behaviour. Verified against the file
      # `Everything Everywhere All at Once.mkv` (HEVC 10-bit, AC-3 5.1)
      # where the orphan ffmpeg's segment 20 had start_pts=130s while
      # the playlist advertised t=120s — a 10s mismatch from negative-DTS
      # wraparound.
      def hls_timestamp_args(job)
        return [] unless job.stream_copy_video?
        [ '-copyts', '-avoid_negative_ts', 'disabled', '-start_at_zero',
         '-muxdelay', '0', '-muxpreload', '0' ]
      end

      # Segment container is locked at job creation; pre-compute so the
      # bitstream-filter + muxer-tag branches see the same value.
      def hls_output_args(job, playlist_path:, segment_template:)
        container = job_segment_container(job)

        # The `{h264,hevc}_mp4toannexb` bitstream filter converts MP4-
        # style length-prefixed NALs into Annex B (start-code-prefixed)
        # so the MPEG-TS muxer can frame them. Two gates, both from
        # upstream EncodingHelper.GetProgressiveVideoArguments
        # (MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs:7633-
        # 7644):
        #
        #   1. Stream-copy only. Software (libx264) and HW encoders
        #      (h264_videotoolbox, ...) already emit Annex B for
        #      `-f hls`/`-f mpegts`; running the filter again double-
        #      converts and Safari/MSE reject the segments with
        #      MEDIA_ERR_SRC_NOT_SUPPORTED.
        #
        #   2. MPEG-TS output only. fMP4 segments KEEP the length-
        #      prefixed NAL form, so applying the Annex-B filter on the
        #      fMP4 path produces malformed fragments — Safari rejects
        #      with MEDIA_ERR_DECODE before the first frame. Upstream
        #      gates on `state.OutputContainer == "ts"`.
        args = if job.stream_copy_video? && container != 'mp4'
                 BitstreamFilters.for(
                   target_container: 'hls',
                   video_codec: job.video_stream&.codec || job.output_video_codec,
                   audio_codec: job.output_audio_codec,
                   source_is_avc: job.video_stream&.is_avc
                 )
        else
                 []
        end
        args.concat(hls_timestamp_args(job))
        # `-max_muxing_queue_size 128` matches upstream Jellyfin
        # (DynamicHlsController.cs:1637) and buffers packets across A/V
        # drift on MKV sources with sparse keyframes.
        args.concat([ '-max_muxing_queue_size', '128' ])
        # NOTE: we intentionally do NOT pass `-max_delay 5000000` like
        # upstream does. On the `h264_videotoolbox` path, that flag
        # interacts with the encoder lookahead such that segment 0's
        # first PTS lands at ~10s instead of the normal ~1.4s VBV
        # pre-roll, making Safari's native HLS engine refuse to start
        # playback (currentTime stuck at 0, ~10s gap to first content
        # → MEDIA_ERR_SRC_NOT_SUPPORTED). Verified by bisecting the
        # ffmpeg arg set on Apple Silicon against the file
        # `Everything Everywhere All at Once.mkv` — adding `-max_delay
        # 5000000` to the otherwise-clean command flipped segment 0's
        # start_pts from 127920 (1.421s) to 901920 (10.021s).
        # Upstream tolerates this flag because libx264 doesn't trigger
        # the same muxer interleave behaviour as videotoolbox.
        # Playlist type follows EncodingJobInfo.IsSegmentedLiveStream:
        # live streams use a sliding window (`live`); finite VOD content
        # uses a vod playlist with EXT-X-ENDLIST appended when ffmpeg
        # finishes. Matches upstream's
        # `-hls_playlist_type {(isEventPlaylist ? "event" : "vod")}`.
        playlist_type = live_segmented?(job) ? 'live' : 'vod'
        # Segment container: mpegts (default, for h264) or fmp4 (HEVC /
        # AV1 stream-copy path, matching what upstream Jellyfin serves
        # Safari for HEVC content). fMP4 needs an init segment + the
        # `-tag:v hvc1` muxer hint so Apple players accept the HEVC
        # sample entry — without `-tag:v hvc1`, ffmpeg writes `hev1`
        # which Safari rejects (output ends up as 24-byte stub fmp4
        # fragments).
        if container == 'mp4'
          # `-tag:v hvc1` must precede the muxer args. It's harmless
          # for non-HEVC codecs (the muxer just ignores it), so we
          # always emit it on the fmp4 path.
          args.concat([ '-tag:v', 'hvc1' ])
        end
        args.concat([
          '-f', 'hls',
          '-hls_time', job.segment_length.to_s,
          '-hls_playlist_type', playlist_type,
          '-hls_list_size', '0',
          '-hls_flags', 'independent_segments+temp_file',
          '-hls_segment_type', container == 'mp4' ? 'fmp4' : 'mpegts'
        ])
        if container == 'mp4'
          # Init segment filename is relative to the output directory;
          # ffmpeg writes it alongside the media segments. Matches the
          # `EXT-X-MAP:URI="-1.mp4"` the engine's master playlist will
          # emit and the route the controller serves it through.
          args.concat([ '-hls_fmp4_init_filename', '-1.mp4' ])
          # `movflags=+frag_discont` mirrors upstream
          # DynamicHlsController.cs:1611 — without it the fMP4 muxer
          # rewrites first-frag DTS/PTS to start from 0 (losing the
          # `-copyts` chain we set up above) and Safari refuses to
          # decode because the playlist's #EXTINF cannot match a
          # zero-based segment 0 against the source's
          # encoder-pre-roll-shifted first keyframe.
          args.concat([ '-hls_segment_options', 'movflags=+frag_discont' ])
        end
        args.concat([ '-hls_segment_filename', segment_template ])
        # AES-128 encryption opt-in. EncodingOptions#hls_encryption_material is
        # set by the controller / Manager when the request asked for it.
        args.concat(Jellyfin::Output::HlsEncryption.output_args(job.options.hls_encryption_material))
        args << playlist_path
        args
      end

      # Looks up the per-job segment container preference. Backed by
      # `TranscodingJob#segment_container` when the caller is the real
      # manager; falls back to `params[:segment_container]` for direct
      # `EncodingJobInfo` callers (tests, ad-hoc CLI use).
      def job_segment_container(job)
        return job.segment_container if job.respond_to?(:segment_container) && job.segment_container
        params = job.respond_to?(:params) ? job.params : nil
        (params && params[:segment_container]).to_s.empty? ? 'ts' : params[:segment_container].to_s
      end

      # Mirrors EncodingJobInfo.IsSegmentedLiveStream:
      #   `TranscodingType != Progressive && !RunTimeTicks.HasValue`
      # In our world we don't have a TranscodingType enum, so we treat
      # "no run-time on the media source" as the live signal.
      def live_segmented?(job)
        rtt = job.media_source.respond_to?(:run_time_ticks) ? job.media_source.run_time_ticks : nil
        rtt.nil? || rtt.to_i.zero?
      end

      private

      def video_index(job)
        return 0 unless job.video_stream
        videos = job.media_source.video_streams
        videos.index { |s| s.index == job.video_stream.index } || 0
      end

      def audio_index(job)
        return 0 unless job.audio_stream
        audios = job.media_source.audio_streams
        audios.index { |s| s.index == job.audio_stream.index } || 0
      end
    end
  end
end
