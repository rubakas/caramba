require 'jellyfin/transcoding/token'

module Jellyfin
  # Direct play endpoint: serves the source file directly with HTTP Range
  # support. Mirrors upstream's `FileStreamResponseHelpers.GetStaticFileResult`
  # (Jellyfin.Api/Helpers/FileStreamResponseHelpers.cs:109), which returns
  # `new PhysicalFileResult(path, contentType) { EnableRangeProcessing = true }`
  # — ASP.NET's built-in Range-aware file response.
  #
  # Rails' `send_file` does NOT parse Range headers itself — it relies on an
  # upstream X-Sendfile / nginx in production. In dev (just Puma) every Range
  # request was answered with the full file from byte 0, which broke seek and
  # caused multi-minute startup for resume points: ExoPlayer needs to fetch
  # the mkv cue index (typically at end-of-file), and without 206 Partial
  # Content it pulled the entire ~700 MB to find it.
  #
  # We implement single-range parsing here (sufficient for ExoPlayer / hls.js
  # / Safari native HLS / Chrome <video>; none of them issue multipart
  # ranges). The body is an Enumerator that seeks once and streams 64 KiB
  # chunks so memory stays bounded for arbitrarily large files.
  class StreamController < ApplicationController
    CHUNK_SIZE = 64 * 1024

    def show
      payload = Jellyfin::Transcoding::Token.decode(params[:token])
      path = payload[:path].to_s

      unless Jellyfin::Rails.configuration.path_allowed?(path)
        return render json: { error: 'path not allowed' }, status: :forbidden
      end
      unless File.exist?(path)
        return render json: { error: 'file not found' }, status: :not_found
      end

      file_size = File.size(path)
      response.headers['Accept-Ranges']      = 'bytes'
      response.headers['Content-Type']       = content_type_for(path)
      response.headers['Content-Disposition'] = "inline; filename=\"#{File.basename(path)}\""

      range_header = request.headers['Range']
      if range_header.blank?
        response.headers['Content-Length'] = file_size.to_s
        response.status = 200
        self.response_body = head_request? ? [] : stream_file(path, 0, file_size - 1)
        return
      end

      parsed = parse_range(range_header, file_size)
      unless parsed
        response.headers['Content-Range'] = "bytes */#{file_size}"
        response.status = 416
        self.response_body = []
        return
      end

      first, last = parsed
      response.headers['Content-Range']  = "bytes #{first}-#{last}/#{file_size}"
      response.headers['Content-Length'] = (last - first + 1).to_s
      response.status = 206
      self.response_body = head_request? ? [] : stream_file(path, first, last)
    rescue Jellyfin::Transcoding::Token::InvalidToken => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def head_request?
      request.head?
    end

    # Lazily yields [first, last] bytes from path in CHUNK_SIZE blocks. The
    # File.open block closes the handle when the Rack body is fully consumed
    # OR when the connection drops (the yielder raises on a dead socket and
    # the block's ensure cleanup runs).
    def stream_file(path, first, last)
      Enumerator.new do |yielder|
        File.open(path, 'rb') do |io|
          io.seek(first)
          remaining = last - first + 1
          while remaining.positive?
            chunk = io.read([CHUNK_SIZE, remaining].min)
            break if chunk.nil? || chunk.empty?
            yielder << chunk
            remaining -= chunk.bytesize
          end
        end
      end
    end

    # Parses a single Range header per RFC 7233. Returns [first, last] inclusive,
    # or nil if the header is malformed / unsatisfiable. Multi-range
    # (`bytes=0-9,20-29`) is intentionally unsupported — no media client we
    # target uses it, and serving it correctly requires multipart/byteranges.
    def parse_range(header, file_size)
      m = header.match(/\Abytes=(\d*)-(\d*)\z/)
      return nil unless m
      first_str, last_str = m[1], m[2]
      return nil if first_str.empty? && last_str.empty?

      if first_str.empty?
        # Suffix range: -N means "last N bytes"
        suffix = last_str.to_i
        return nil if suffix <= 0
        [[file_size - suffix, 0].max, file_size - 1]
      elsif last_str.empty?
        first = first_str.to_i
        return nil if first >= file_size
        [first, file_size - 1]
      else
        first = first_str.to_i
        last  = last_str.to_i
        return nil if first > last || first >= file_size
        [first, [last, file_size - 1].min]
      end
    end

    def content_type_for(path)
      ext = File.extname(path).delete('.').downcase
      case ext
      when 'mp4', 'm4v' then 'video/mp4'
      when 'mov'        then 'video/quicktime'
      when 'mkv'        then 'video/x-matroska'
      when 'webm'       then 'video/webm'
      when 'ts'         then 'video/mp2t'
      when 'avi'        then 'video/x-msvideo'
      when 'flv'        then 'video/x-flv'
      when 'mp3'        then 'audio/mpeg'
      when 'flac'       then 'audio/flac'
      when 'aac'        then 'audio/aac'
      when 'm4a'        then 'audio/mp4'
      when 'ogg'        then 'audio/ogg'
      when 'wav'        then 'audio/wav'
      else                   'application/octet-stream'
      end
    end
  end
end
