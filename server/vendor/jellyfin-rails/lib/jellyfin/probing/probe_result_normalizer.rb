require 'jellyfin/probing/media_source_info'
require 'jellyfin/probing/media_stream'

module Jellyfin
  module Probing
    # Subset of MediaBrowser.MediaEncoding/Probing/ProbeResultNormalizer.cs.
    # Translates ffprobe JSON into MediaSourceInfo + MediaStream PODs.
    #
    # The full upstream normalizer is 1,768 LOC and handles DVD/Blu-ray quirks,
    # 3D detection, extended metadata, embedded chapters from many container
    # formats, etc. We port the ~400 LOC core needed for HLS transcoding.
    class ProbeResultNormalizer
      TICKS_PER_SECOND = 10_000_000

      def self.call(json, path:)
        new(json, path: path).call
      end

      def initialize(json, path:)
        @json = json
        @path = path
      end

      def call
        format = @json['format'] || {}
        streams = (@json['streams'] || []).map { |s| build_stream(s) }
        chapters = (@json['chapters'] || []).map { |c| build_chapter(c) }
        programs = (@json['programs'] || []).map { |p| build_program(p) }

        MediaSourceInfo.new(
          id: derive_id,
          path: @path,
          protocol: protocol_for(@path),
          container: normalize_container(format['format_name']),
          run_time_ticks: parse_ticks(format['duration']),
          bit_rate: format['bit_rate']&.to_i,
          size: format['size']&.to_i,
          format_name: format['format_name'],
          streams: streams,
          chapters: chapters,
          programs: programs,
          tags: format['tags'] || {}
        )
      end

      private

      def derive_id
        Digest::SHA1.hexdigest(@path)[0, 16]
      end

      def protocol_for(path)
        return 'http' if path.to_s.start_with?('http://', 'https://')
        'file'
      end

      def normalize_container(format_name)
        return nil unless format_name
        # ffprobe returns comma-separated lists like "mov,mp4,m4a,3gp,3g2,mj2"; pick the first.
        first = format_name.split(',').first.to_s.strip
        case first
        when 'matroska' then 'mkv'
        when 'mov' then 'mp4'
        else first
        end
      end

      def parse_ticks(duration_str)
        return nil if duration_str.nil? || duration_str == 'N/A'
        (duration_str.to_f * TICKS_PER_SECOND).to_i
      end

      def build_stream(s)
        type = s['codec_type'].to_s.to_sym
        common = {
          index: s['index'],
          type: type,
          codec: s['codec_name'],
          codec_tag: s['codec_tag_string'],
          profile: s['profile'],
          level: s['level'],
          bit_rate: s['bit_rate']&.to_i,
          is_default: dispo(s, 'default'),
          is_forced:  dispo(s, 'forced'),
          language:   s.dig('tags', 'language'),
          title:      s.dig('tags', 'title')
        }

        case type
        when :video
          MediaStream.new(**common, **video_attrs(s))
        when :audio
          MediaStream.new(**common, **audio_attrs(s))
        when :subtitle
          MediaStream.new(**common)
        else
          MediaStream.new(**common)
        end
      end

      def video_attrs(s)
        side = (s['side_data_list'] || [])
        side_types = side.map { |d| d['side_data_type'].to_s }
        video_range, video_range_type = derive_video_range(s, side_types)
        field_order = s['field_order'].to_s
        r_rate  = rational(s['r_frame_rate'])
        avg     = rational(s['avg_frame_rate'])

        {
          width: s['width'],
          height: s['height'],
          pixel_format: s['pix_fmt'],
          bit_depth: derive_bit_depth(s),
          display_aspect_ratio: s['display_aspect_ratio'],
          sample_aspect_ratio: s['sample_aspect_ratio'],
          frame_rate: r_rate,
          avg_frame_rate: avg,
          is_vfr: vfr?(r_rate, avg),
          color_range: s['color_range'],
          color_space: s['color_space'],
          color_transfer: s['color_transfer'],
          color_primaries: s['color_primaries'],
          video_range: video_range,
          video_range_type: video_range_type,
          max_cll: extract_max_cll(side),
          max_fall: extract_max_fall(side),
          mastering_display: extract_mastering_display(side),
          dovi_profile: extract_dovi(side, 'dv_profile'),
          dovi_rpu_present: extract_dovi(side, 'rpu_present_flag'),
          dovi_bl_present: extract_dovi(side, 'bl_present_flag'),
          dovi_el_present: extract_dovi(side, 'el_present_flag'),
          is_avc: s['is_avc'] == 'true',
          nal_length_size: s['nal_length_size']&.to_i,
          refs: s['refs'],
          has_b_frames: s['has_b_frames']&.to_i,
          field_order: field_order,
          is_interlaced: %w[tt bb tb bt].include?(field_order),
          gop_size: s['gop_size']&.to_i,
          # gop_closed isn't reported by ffprobe; needs frame-level inspection.
          # GopAnalyzer fills this on demand; nil = "unknown".
          gop_closed: nil,
          rotation: extract_rotation(s, side),
          hdr10plus_present: side_types.any? { |t| t.to_s.include?('HDR10+') || t.to_s.include?('SMPTE2094-40') },
          closed_captions: s['closed_captions']&.to_i,
          has_closed_captions: side_types.any? { |t| t.to_s.include?('Closed captions') } || s['closed_captions'].to_i.positive?,
          # Stereo 3D format detection — side-data first, then filename pattern.
          # Mirrors upstream ProbeResultNormalizer's `Video3DFormat` handling.
          stereo_3d: Jellyfin::Probing::Stereo3d.detect(side, @path),
          codec_long_name: s['codec_long_name']
        }
      end

      def derive_bit_depth(s)
        return s['bits_per_raw_sample'].to_i if s['bits_per_raw_sample']
        pf = s['pix_fmt'].to_s
        return 12 if pf.include?('12')
        return 10 if pf.include?('10')
        8
      end

      # Returns true if r_frame_rate and avg_frame_rate diverge meaningfully
      # (>5% delta), which is the standard heuristic for variable frame rate.
      def vfr?(r_rate, avg_rate)
        return false if r_rate.nil? || avg_rate.nil? || avg_rate.zero?
        ((r_rate - avg_rate).abs / avg_rate) > 0.05
      end

      def extract_max_cll(side)
        cll = side.find { |d| d['side_data_type'].to_s.include?('Content light level') }
        cll && cll['max_content']&.to_i
      end

      def extract_max_fall(side)
        cll = side.find { |d| d['side_data_type'].to_s.include?('Content light level') }
        cll && cll['max_average']&.to_i
      end

      def extract_mastering_display(side)
        m = side.find { |d| d['side_data_type'].to_s.include?('Mastering display') }
        return nil unless m
        # Pass through the relevant fields as-is.
        m.slice(*%w[
          red_x red_y green_x green_y blue_x blue_y white_point_x white_point_y
          min_luminance max_luminance
        ])
      end

      def extract_dovi(side, key)
        d = side.find { |x| x['side_data_type'].to_s == 'DOVI configuration record' }
        d && d[key]
      end

      # Rotation lives in two places depending on container: a side_data record
      # of type "Display Matrix" (ffprobe parses the matrix into a rotation int),
      # or a `tags.rotate` for older containers (mp4 metadata). Returns degrees
      # rounded to the nearest 90; 0 if not present.
      def extract_rotation(s, side)
        display_matrix = side.find { |x| x['side_data_type'].to_s == 'Display Matrix' }
        rot = display_matrix && display_matrix['rotation']
        rot ||= s.dig('tags', 'rotate')
        return 0 if rot.nil?
        deg = rot.to_f.round
        # Normalize to 0/90/180/270.
        ((deg % 360) + 360) % 360
      end

      def audio_attrs(s)
        {
          channels: s['channels'],
          channel_layout: s['channel_layout'],
          sample_rate: s['sample_rate']&.to_i,
          bit_depth: (s['bits_per_raw_sample'] || s['bits_per_sample'])&.to_i,
          codec_long_name: s['codec_long_name']
        }
      end

      # Derives (range, range_type) following Jellyfin's logic:
      #   range ∈ { "SDR", "HDR" }
      #   range_type ∈ { "SDR", "HDR10", "HDR10Plus", "DOVI", "HLG" }
      def derive_video_range(s, side)
        return ['SDR', 'SDR'] unless s['codec_type'] == 'video'

        transfer = s['color_transfer'].to_s
        is_dovi  = side.include?('DOVI configuration record')
        is_hdr10plus = side.include?('HDR Dynamic Metadata SMPTE2094-40 (HDR10+)')

        return ['HDR', 'DOVI']      if is_dovi
        return ['HDR', 'HDR10Plus'] if is_hdr10plus
        return ['HDR', 'HLG']       if transfer == 'arib-std-b67'
        return ['HDR', 'HDR10']     if %w[smpte2084 smpte428].include?(transfer)
        ['SDR', 'SDR']
      end

      def dispo(stream, key)
        v = stream.dig('disposition', key)
        v.to_i == 1
      end

      def rational(str)
        return nil if str.nil? || str == '0/0'
        n, d = str.split('/').map(&:to_f)
        return nil if d.nil? || d.zero?
        n / d
      end

      def build_chapter(c)
        {
          id: c['id'],
          start_time: c['start_time']&.to_f,
          end_time: c['end_time']&.to_f,
          title: c.dig('tags', 'title')
        }
      end

      def build_program(p)
        {
          program_id: p['program_id'],
          program_num: p['program_num'],
          nb_streams: p['nb_streams'],
          streams: (p['streams'] || []).map { |s| s['index'] },
          tags: p['tags'] || {}
        }
      end
    end
  end
end
