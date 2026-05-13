require 'jellyfin/encoding/hwaccel/base'
require 'jellyfin/encoding/hwaccel/videotoolbox'
require 'jellyfin/encoding/hwaccel/vaapi'
require 'jellyfin/encoding/hwaccel/nvenc'
require 'jellyfin/encoding/hwaccel/qsv'

module Jellyfin
  module Encoding
    module Hwaccel
      BACKENDS = {
        videotoolbox: Videotoolbox,
        vaapi:        Vaapi,
        nvenc:        Nvenc,
        qsv:          Qsv
      }.freeze

      module_function

      def for(name)
        return nil if name.nil? || name == :none
        BACKENDS.fetch(name.to_sym) { raise ArgumentError, "unknown HW accel: #{name}" }
      end

      def autodetect(capabilities)
        BACKENDS.each { |_n, backend| return backend if backend.available?(capabilities) }
        nil
      end
    end
  end
end
