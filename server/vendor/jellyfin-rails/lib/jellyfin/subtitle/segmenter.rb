require 'fileutils'
require 'open3'
require 'digest'
require 'jellyfin/transcoding/async_keyed_locker'

module Jellyfin
  module Subtitle
    # Slices a full-source WebVTT into per-HLS-segment chunks so the resulting
    # subtitle playlist aligns frame-for-frame with the video segments.
    #
    # ffmpeg's hls muxer does this automatically for video; for subtitles we
    # have to drive it manually. The flow:
    #
    #   1) extract the source subtitle stream to a single .vtt file
    #   2) parse the cues
    #   3) write one .vtt per HLS segment, containing only cues whose
    #      [start, end) overlap [seg_start, seg_end)
    #   4) emit a per-track HLS playlist that references the segment .vtts
    #
    # Mirrors the segmenter logic upstream's HlsHelpers uses around
    # `WriteSegmentToFile`. We keep it lazy: callers extract+segment once per
    # (source path, stream index, segment length) and cache by those keys.
    class Segmenter
      Cue = Struct.new(:start_seconds, :end_seconds, :text, keyword_init: true)

      WEBVTT_HEADER = "WEBVTT\n\n".freeze

      def initialize(ffmpeg_path:, cache_root:)
        @ffmpeg = ffmpeg_path
        @cache_root = cache_root
      end

      # Builds segments and the per-track playlist. Returns a hash:
      #   { playlist:, segment_dir:, count:, language:, name: }
      #
      # Concurrent calls for the same `(source_path, stream_index)` are
      # serialised through `AsyncKeyedLocker`: Safari fetches every
      # `EXT-X-MEDIA:TYPE=SUBTITLES` URI in the master playlist in
      # parallel (Forced/Full/SDH = 3 simultaneous index requests), and
      # without the lock each spawned its own `ffmpeg ... -c:s webvtt`
      # against the same source — multiple writers racing on the same
      # `full.vtt`, blocking on filesystem, > 8s wall time. Safari then
      # gave up on the master with MEDIA_ERR_SRC_NOT_SUPPORTED. Upstream
      # Jellyfin serialises through `SubtitleManager.GetRemoteSubtitles`
      # / file locks; we mirror that here.
      def segment(source_path:, stream_index:, segment_length:, language: nil, name: nil)
        return nil unless File.exist?(source_path)
        dir = cache_dir_for(source_path, stream_index)

        Jellyfin::Transcoding::AsyncKeyedLocker.instance.with("subs:#{dir}") do
          manifest_path = File.join(dir, 'manifest.json')
          if File.exist?(manifest_path) && fresh?(manifest_path, source_path)
            return load_manifest(manifest_path).merge(segment_dir: dir)
          end

          FileUtils.rm_rf(dir)
          FileUtils.mkdir_p(dir)

          full_vtt = File.join(dir, 'full.vtt')
          unless extract_to(source_path, stream_index, full_vtt)
            return nil
          end

          cues = parse_cues(File.read(full_vtt))
          total_duration = cues.map(&:end_seconds).max || 0
          count = (total_duration / segment_length.to_f).ceil
          count = 1 if count.zero?
          count.times do |i|
            seg_start = i * segment_length
            seg_end = (i + 1) * segment_length
            write_segment(dir, i, cues, seg_start, seg_end)
          end

          playlist = build_playlist(count, segment_length, total_duration)
          File.write(File.join(dir, 'index.m3u8'), playlist)

          meta = { 'playlist' => playlist, 'count' => count, 'language' => language,
                   'name' => name, 'mtime' => File.mtime(source_path).to_i }
          File.write(manifest_path, JSON.dump(meta))

          meta.merge('segment_dir' => dir).transform_keys(&:to_sym)
        end
      end

      def segment_path(source_path:, stream_index:, segment_index:)
        File.join(cache_dir_for(source_path, stream_index), "#{segment_index}.vtt")
      end

      def parse_cues(text)
        cues = []
        # Each cue is separated by a blank line. The timestamp line has the
        # shape `HH:MM:SS.mmm --> HH:MM:SS.mmm` (optionally followed by
        # cue-positioning settings).
        text = text.sub(/\AWEBVTT.*?\n\n/m, '')
        text.split(/\n\n+/).each do |block|
          lines = block.split("\n")
          tline = lines.find { |l| l.include?('-->') }
          next unless tline
          # Strip optional cue identifier (any line BEFORE the timestamp line)
          ts_idx = lines.index(tline)
          payload = lines[(ts_idx + 1)..]&.join("\n")&.strip
          next unless payload && !payload.empty?
          start_ts, end_ts = tline.split('-->').map(&:strip)
          # Drop cue settings after the end timestamp.
          end_ts = end_ts.split(/\s+/).first
          cues << Cue.new(start_seconds: parse_ts(start_ts),
                          end_seconds: parse_ts(end_ts),
                          text: payload)
        end
        cues
      end

      # Public helper for the controller — formats one timestamp.
      def format_ts(seconds)
        h = (seconds / 3600).to_i
        m = ((seconds % 3600) / 60).to_i
        s = seconds % 60
        format('%02d:%02d:%06.3f', h, m, s)
      end

      private

      def cache_dir_for(source, idx)
        digest = Digest::SHA1.hexdigest("#{File.expand_path(source)}|#{idx}")
        File.join(@cache_root, 'subs', 'segments', digest)
      end

      def fresh?(manifest_path, source_path)
        require 'json'
        data = JSON.parse(File.read(manifest_path))
        data['mtime'].to_i == File.mtime(source_path).to_i
      rescue StandardError
        false
      end

      def load_manifest(manifest_path)
        require 'json'
        JSON.parse(File.read(manifest_path)).transform_keys(&:to_sym)
      end

      def extract_to(source_path, stream_index, out_path)
        # `0:#{n}` selects the absolute stream index in the file (matches
        # ffprobe's stream.index — what callers carry around). The previous
        # `0:s:#{n}` selected the Nth SUBTITLE stream (0-indexed within
        # subtitles only), which silently misaligned whenever the source had
        # video + audio streams before the subtitle group: a file with 1
        # video, 3 audio, 3 subtitle streams (typical) sent `-map 0:s:4` for
        # global index 4 (= first subtitle), asking ffmpeg for the FIFTH
        # subtitle stream — which doesn't exist. extract_to returned false,
        # segmenter returned nil, and webvtt#index returned 404. Using the
        # absolute index sidesteps the indexing-domain mismatch.
        cmd = [@ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
               '-i', source_path,
               '-map', "0:#{stream_index}",
               '-c:s', 'webvtt',
               out_path]
        _out, _err, status = Open3.capture3(*cmd)
        status.success? && File.exist?(out_path)
      end

      def write_segment(dir, index, cues, seg_start, seg_end)
        path = File.join(dir, "#{index}.vtt")
        # Cue overlaps the segment window iff cue.end > seg_start AND
        # cue.start < seg_end. We don't trim cue timestamps — players display
        # the original times.
        slice = cues.select { |c| c.end_seconds > seg_start && c.start_seconds < seg_end }
        body = slice.map do |c|
          "#{format_ts(c.start_seconds)} --> #{format_ts(c.end_seconds)}\n#{c.text}"
        end.join("\n\n")
        File.write(path, WEBVTT_HEADER + body + (body.empty? ? '' : "\n"))
      end

      def build_playlist(count, segment_length, total_duration)
        lines = ['#EXTM3U', '#EXT-X-VERSION:6',
                 "#EXT-X-TARGETDURATION:#{segment_length}",
                 '#EXT-X-PLAYLIST-TYPE:VOD',
                 '#EXT-X-MEDIA-SEQUENCE:0']
        elapsed = 0.0
        count.times do |i|
          dur = [segment_length.to_f, total_duration - elapsed].min.clamp(0, segment_length)
          dur = segment_length.to_f if dur <= 0
          lines << "#EXTINF:#{format('%.3f', dur)},"
          lines << "#{i}.vtt"
          elapsed += dur
        end
        lines << '#EXT-X-ENDLIST'
        lines.join("\n")
      end

      def parse_ts(ts)
        # WebVTT supports both `HH:MM:SS.mmm` and `MM:SS.mmm`. Normalise.
        parts = ts.split(':')
        if parts.size == 3
          h, m, s = parts
          h.to_f * 3600 + m.to_f * 60 + s.to_f
        else
          m, s = parts
          m.to_f * 60 + s.to_f
        end
      end
    end
  end
end
