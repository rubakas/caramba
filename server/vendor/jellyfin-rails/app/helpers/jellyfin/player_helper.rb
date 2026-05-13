module Jellyfin
  module PlayerHelper
    # <%= jellyfin_player(path: video.path, autoplay: true,
    #                     subtitles: [{ url: ... }],
    #                     reporter_url: api_progress_path(video)) %>
    #
    # Signs a transcode token server-side, renders a <jellyfin-player> element
    # pointing at the master.m3u8 URL. No client-side round-trip to /transcode/start.
    def jellyfin_player(path:, **opts)
      raise ArgumentError, 'path is required' if path.nil? || path.empty?
      unless Jellyfin::Rails.configuration.path_allowed?(path)
        raise ArgumentError, "path not allowed by Jellyfin::Rails.configuration: #{path}"
      end

      payload = {
        path: path,
        video_codec: opts[:video_codec],
        video_bitrate: opts[:video_bitrate],
        audio_codec: opts[:audio_codec],
        audio_bitrate: opts[:audio_bitrate],
        max_height: opts[:max_height],
        video_track: opts[:video_track],
        audio_track: opts[:audio_track],
        subtitle_track: opts[:subtitle_track],
        segment_length: opts[:segment_length]
      }.compact

      token = Jellyfin::Transcoding::Token.encode(payload)
      master_url = main_app_master_url(token)

      attrs = {
        src: master_url,
        controls: opts.fetch(:controls, true).to_s,
        autoplay: opts[:autoplay] ? '' : nil,
        volume: opts[:volume],
        'reporter-url': opts[:reporter_url]
      }.compact

      if block_given?
        builder = PlayerBuilder.new
        yield builder
        slot_html = builder.render(self)
        content_tag(:'jellyfin-player', slot_html.html_safe, attrs)
      else
        content_tag(:'jellyfin-player', '', attrs)
      end
    end

    # Captures slot blocks for the jellyfin_player view helper.
    #
    #   <%= jellyfin_player(path: ...) do |p| %>
    #     <% p.slot :overlay_top do %>...<% end %>
    #     <% p.slot :controls_right do %>...<% end %>
    #   <% end %>
    class PlayerBuilder
      ALLOWED = %i[overlay_top overlay_bottom controls_left controls_center controls_right sidebar].freeze

      def initialize
        @slots = {}
      end

      def slot(name, &block)
        raise ArgumentError, "unknown slot: #{name}" unless ALLOWED.include?(name)
        @slots[name] = block
      end

      def render(view)
        @slots.map do |name, block|
          slot_name = name.to_s.tr('_', '-')
          view.content_tag(:div, view.capture(&block), slot: slot_name, class: "jellyfin-slot-content jellyfin-slot-content--#{slot_name}")
        end.join
      end
    end

    private

    def main_app_master_url(token)
      Jellyfin::Rails::Engine.routes.url_helpers.master_path(token: token)
    end
  end
end
