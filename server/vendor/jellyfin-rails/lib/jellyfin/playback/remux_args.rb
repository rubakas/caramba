module Jellyfin
  module Playback
    # Builds ffmpeg args for "direct stream" mode — `-c copy` into a target
    # container. Cheaper than full transcode (~5–10× faster, no quality loss)
    # but still uses an ffmpeg process to rewrite the container.
    module RemuxArgs
      module_function

      def call(source_path:, output_path:, target_container: 'mp4',
               video_track: 0, audio_track: 0, fast_start: true,
               video_codec: 'h264', audio_codec: 'aac')
        args = ['-hide_banner', '-loglevel', 'warning', '-y',
                '-fflags', '+genpts',
                '-i', source_path,
                '-map', "0:v:#{video_track}",
                '-map', "0:a:#{audio_track}?",
                '-c', 'copy']
        # Bitstream filters required by various source→container combos.
        args.concat(Jellyfin::Encoding::BitstreamFilters.for(
          target_container: target_container,
          video_codec: video_codec,
          audio_codec: audio_codec
        ))
        # `+faststart` puts the moov atom at the head of the file so progressive
        # download can begin playback before the whole file arrives. Skipped for
        # streaming to pipe:1 — faststart needs a seekable output.
        args.concat(['-movflags', '+faststart']) if target_container == 'mp4' && fast_start && output_path != 'pipe:1'
        args.concat(['-f', ffmpeg_format(target_container), output_path])
        args
      end

      def ffmpeg_format(container)
        case container.to_s.downcase
        when 'mp4', 'm4v'   then 'mp4'
        when 'mkv'          then 'matroska'
        when 'webm'         then 'webm'
        when 'ts'           then 'mpegts'
        when 'hls'          then 'hls'
        else                     container.to_s
        end
      end
    end
  end
end
