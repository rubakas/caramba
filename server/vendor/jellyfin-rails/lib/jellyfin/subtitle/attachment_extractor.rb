require 'fileutils'
require 'open3'

module Jellyfin
  module Subtitle
    # Mirrors AttachmentExtractor.cs — pulls embedded MKV font attachments out
    # to a cache dir so the `subtitles` filter can find them when rendering
    # ASS/SSA subtitle styles.
    #
    # Caches by (source path mtime, source size) so a re-extract isn't done on
    # every playback. Cache invalidation: file changed → rebuild.
    class AttachmentExtractor
      FONT_MIME = %w[application/x-truetype-font application/vnd.ms-opentype font/ttf font/otf application/font-sfnt].freeze
      FONT_EXT  = %w[.ttf .otf .ttc .pfb .woff .woff2].freeze

      Attachment = Struct.new(:filename, :path, :mimetype, keyword_init: true)

      def initialize(ffmpeg_path:, cache_root:, ffprobe_path: nil)
        @ffmpeg = ffmpeg_path
        @ffprobe = ffprobe_path || ffmpeg_path.to_s.sub(/ffmpeg(\.exe)?$/, 'ffprobe\1')
        @cache_root = cache_root
      end

      # Returns an array of `Attachment` records. Idempotent — uses the cache
      # if the source file hasn't changed.
      def extract(source_path)
        return [] unless File.exist?(source_path)
        dir = cache_dir_for(source_path)
        manifest = File.join(dir, 'manifest.json')

        if cache_valid?(source_path, manifest)
          return load_manifest(manifest, dir)
        end

        FileUtils.rm_rf(dir)
        FileUtils.mkdir_p(dir)

        atts = run_extract(source_path, dir)
        write_manifest(manifest, source_path, atts)
        atts
      end

      def cache_dir_for(source_path)
        digest = Digest::SHA1.hexdigest(File.expand_path(source_path))
        File.join(@cache_root, 'subs', 'fonts', digest)
      end

      private

      def cache_valid?(source_path, manifest)
        return false unless File.exist?(manifest)
        require 'json'
        data = JSON.parse(File.read(manifest))
        stat = File.stat(source_path)
        data['mtime'].to_i == stat.mtime.to_i && data['size'].to_i == stat.size
      rescue StandardError
        false
      end

      def load_manifest(manifest, dir)
        require 'json'
        data = JSON.parse(File.read(manifest))
        (data['attachments'] || []).map do |entry|
          Attachment.new(
            filename: entry['filename'],
            path: File.join(dir, entry['filename']),
            mimetype: entry['mimetype']
          )
        end
      end

      def write_manifest(manifest, source_path, attachments)
        require 'json'
        stat = File.stat(source_path)
        File.write(manifest, JSON.dump(
          mtime: stat.mtime.to_i,
          size: stat.size,
          attachments: attachments.map { |a| { 'filename' => a.filename, 'mimetype' => a.mimetype } }
        ))
      end

      # ffmpeg lists attachment streams via -dump_attachment. The technique:
      # 1) probe the file for attachment streams + their metadata
      # 2) call ffmpeg once per attachment with `-dump_attachment:t:<i>`
      #
      # We could batch with a single ffmpeg invocation but ffmpeg refuses to
      # mix multiple dump_attachment writes in one call.
      def run_extract(source_path, dir)
        atts = []
        list_attachments(source_path).each_with_index do |meta, idx|
          out_name = sanitize_filename(meta[:filename] || "attachment-#{idx}")
          out_path = File.join(dir, out_name)
          cmd = [@ffmpeg, '-y', '-loglevel', 'error',
                 "-dump_attachment:t:#{idx}", out_path,
                 '-i', source_path]
          _stdout, _stderr, status = Open3.capture3(*cmd)
          # ffmpeg returns 1 for dump_attachment runs even on success because it
          # never finds an output stream. Check for the file instead.
          if File.exist?(out_path) && File.size(out_path).positive?
            atts << Attachment.new(filename: out_name, path: out_path, mimetype: meta[:mimetype])
          elsif !status.success?
            # propagate failure for unit tests but tolerate the well-known case
          end
        end
        atts.select { |a| font?(a) }
      end

      # ffprobe is the canonical way to enumerate attachment streams. The JSON
      # output is stable across ffmpeg versions, unlike the stderr-formatted
      # `-i` listing which changes between releases.
      def list_attachments(source_path)
        require 'json'
        cmd = [@ffprobe, '-v', 'error', '-show_streams', '-of', 'json', source_path]
        out, _err, status = Open3.capture3(*cmd)
        return [] unless status.success?

        data = JSON.parse(out)
        streams = data['streams'] || []
        streams.filter_map do |s|
          next unless s['codec_type'].to_s == 'attachment'
          tags = s['tags'] || {}
          # ffprobe lowercases tag keys differently per container. mkv uses
          # "filename"/"mimetype"; others use "title". Normalise.
          filename = tags['filename'] || tags['FILENAME'] || tags['title']
          mimetype = tags['mimetype'] || tags['MIMETYPE'] || s['codec_name']
          { stream: s['index'].to_i, filename: filename, mimetype: mimetype }
        end
      rescue JSON::ParserError
        []
      end

      def font?(attachment)
        return true if FONT_MIME.include?(attachment.mimetype.to_s.downcase)
        FONT_EXT.include?(File.extname(attachment.filename).downcase)
      end

      def sanitize_filename(name)
        # Strip path separators and control chars to avoid extracting outside the cache dir.
        File.basename(name).gsub(/[^\w.\-]+/, '_')
      end
    end
  end
end
