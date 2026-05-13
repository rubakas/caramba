module Jellyfin
  # Port of SubtitleController.GetFallbackFont (SubtitleController.cs:548).
  #
  # GET /fallback_fonts/:name
  #
  # Serves a font file from the directory configured via
  # `Jellyfin::Rails.configuration.fallback_font_path`. Used by clients that
  # render ASS/SSA subtitles in-browser and need a known typeface for unknown
  # font-family references.
  class FallbackFontsController < ApplicationController
    def show
      base = Jellyfin::Rails.configuration.fallback_font_path
      return head(:not_found) if base.nil? || base.to_s.empty?

      name = params[:name].to_s
      # Reject path traversal — the route constraint already excludes slashes,
      # but defence-in-depth.
      return head(:bad_request) if name.include?('/') || name.include?('..')

      file = Dir.entries(base).find { |e| e.casecmp(name).zero? }
      return head(:not_found) unless file
      full = File.join(base, file)
      return head(:not_found) unless File.file?(full) && File.size(full).positive?

      send_file full, type: mime_for(file), disposition: 'inline'
    rescue Errno::ENOENT, Errno::EACCES
      head :not_found
    end

    private

    def mime_for(name)
      case File.extname(name).downcase
      when '.ttf'  then 'font/ttf'
      when '.otf'  then 'font/otf'
      when '.ttc'  then 'font/collection'
      when '.woff' then 'font/woff'
      when '.woff2' then 'font/woff2'
      else 'application/octet-stream'
      end
    end
  end
end
