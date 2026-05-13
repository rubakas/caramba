require 'fileutils'

module Jellyfin
  module Transcoding
    # Runs N ffmpeg transcodes in parallel — one per ABR ladder rung — and
    # stitches their per-variant playlists into a single HLS master playlist
    # that references all of them. This is the orchestration layer the upstream
    # `DynamicHlsController` provides; we expose it as a small class the
    # controller can drive.
    #
    # Construction is intentionally pure (no I/O); call `start!` to spawn the
    # ffmpeg processes and `stop!` to tear them down.
    class AbrOrchestrator
      attr_reader :variants, :master_path

      Variant = Struct.new(:ladder_rung, :child_job, keyword_init: true)

      def initialize(parent_job:, manager: TranscodeManager.instance, ladder: nil)
        @parent_job = parent_job
        @manager = manager
        @ladder = ladder || Jellyfin::Output::AbrLadder.build(
          source_height: parent_job.params[:source_height],
          source_bitrate: parent_job.params[:source_bitrate],
          max_height: parent_job.params[:max_height],
          max_bitrate: parent_job.params[:max_bitrate] # MaxStreamingBitrate
        )
        @master_path = File.join(parent_job.dir, 'master.m3u8')
        @variants = []
      end

      # Spawns one child transcode per ladder rung. Each child writes its
      # playlist + segments into a per-variant subdirectory.
      def start!
        @ladder.each do |rung|
          subdir = File.join(@parent_job.dir, rung.name)
          FileUtils.mkdir_p(subdir)
          child_id = "#{@parent_job.id}-#{rung.name}"
          child_params = @parent_job.params.merge(
            video_bitrate: rung.video_bitrate,
            audio_bitrate: rung.audio_bitrate,
            max_height: rung.height,
            output_dir: subdir,
            segment_length: @parent_job.segment_length_seconds
          )
          child_job = @manager.ensure_started(id: child_id, params: child_params)
          @variants << Variant.new(ladder_rung: rung, child_job: child_job)
        end
        write_master_playlist!
        self
      end

      def stop!
        @variants.each { |v| @manager.stop!(v.child_job.id) }
        @variants.clear
      end

      # The master playlist references each variant's playlist with the codec
      # string + bandwidth + resolution. Players use these to pick a rung.
      def write_master_playlist!
        lines = ['#EXTM3U', '#EXT-X-VERSION:6', '']
        @variants.each do |v|
          codec_str = Jellyfin::Output::CodecString.for(
            video_codec: @parent_job.params[:video_codec] || 'h264',
            audio_codec: @parent_job.params[:audio_codec] || 'aac',
            profile: 'high', level: 4.1, audio_channels: 2
          )
          attrs = ["BANDWIDTH=#{v.ladder_rung.video_bitrate + v.ladder_rung.audio_bitrate}",
                   %(CODECS="#{codec_str}"),
                   "RESOLUTION=#{v.ladder_rung.width}x#{v.ladder_rung.height}",
                   %(NAME="#{v.ladder_rung.name}")]
          lines << "#EXT-X-STREAM-INF:#{attrs.join(',')}"
          lines << "#{v.ladder_rung.name}/master.m3u8"
          lines << ''
        end
        File.write(@master_path, lines.join("\n"))
      end
    end
  end
end
