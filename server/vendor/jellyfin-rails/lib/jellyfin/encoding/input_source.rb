module Jellyfin
  module Encoding
    # Builds the ffmpeg input arg list, handling four source flavours:
    #
    #   :file    — local path. Just `-i path`.
    #   :http    — remote HTTP/HTTPS. Add reconnect + user-agent + headers.
    #   :concat  — multi-part movie split across files. Use `-f concat -i list`.
    #   :stream  — live network stream (UDP/RTP/RTMP). `-re` for read-rate match.
    #
    # Mirrors EncodingHelper.cs input modifier logic — `-headers`, `-user_agent`,
    # `-reconnect`, `-seekable`, plus the ffmpeg concat demuxer for multi-part
    # sources (which Jellyfin needs for split MKV/AVI rips).
    module InputSource
      DEFAULT_USER_AGENT = 'Jellyfin-rails/1.0'.freeze

      module_function

      # Returns [input_args_array, cleanup_proc]. The cleanup_proc deletes any
      # temporary concat manifest after the spawn returns.
      def build(job)
        type = classify(job.media_source.path, job.options)
        case type
        when :http   then [http_args(job), proc {}]
        when :concat then build_concat(job)
        when :stream then [stream_args(job), proc {}]
        else              [['-i', job.media_source.path], proc {}]
        end
      end

      def classify(path, options)
        return :concat if options.respond_to?(:concat_parts) && options.concat_parts.is_a?(Array) && options.concat_parts.any?
        return :http   if path.to_s.start_with?('http://', 'https://')
        return :stream if path.to_s.match?(/\A(rtsp|rtmp|udp|srt|rtp):/)
        :file
      end

      def http_args(job)
        opts = job.options
        args = []
        args.concat(['-reconnect', '1'])
        args.concat(['-reconnect_streamed', '1'])
        args.concat(['-reconnect_delay_max', '5'])
        args.concat(['-seekable', '1'])
        args.concat(['-user_agent', opts.respond_to?(:http_user_agent) && opts.http_user_agent ? opts.http_user_agent : DEFAULT_USER_AGENT])
        if opts.respond_to?(:http_headers) && opts.http_headers.is_a?(Hash) && opts.http_headers.any?
          # ffmpeg expects all headers as a single \r\n-delimited string after `-headers`.
          flat = opts.http_headers.map { |k, v| "#{k}: #{v}" }.join("\r\n") + "\r\n"
          args.concat(['-headers', flat])
        end
        args.concat(['-i', job.media_source.path])
        args
      end

      def stream_args(job)
        # `-re` makes ffmpeg read in real time. Required for live sources to
        # avoid the encoder racing ahead of available data.
        ['-re', '-i', job.media_source.path]
      end

      def build_concat(job)
        require 'tempfile'
        parts = job.options.concat_parts
        list = Tempfile.new(['concat', '.txt'])
        parts.each do |p|
          list.puts("file '#{p.gsub("'", "'\\\\''")}'")
        end
        list.flush
        args = ['-f', 'concat', '-safe', '0', '-i', list.path]
        cleanup = proc { list.close; list.unlink }
        [args, cleanup]
      end
    end
  end
end
