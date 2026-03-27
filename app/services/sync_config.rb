# Reads and writes the sync configuration from a JSON file.
#
# Stored outside the database (storage/sync_config.json) so the sync
# folder setting survives database replacements during sync.
#
# Usage:
#   SyncConfig.sync_folder              # => "/path/to/folder" or nil
#   SyncConfig.sync_folder = "/path"    # persists to disk
#   SyncConfig.enabled?                 # => true/false
#
class SyncConfig
  CONFIG_PATH = Rails.root.join('storage', 'sync_config.json').freeze

  class << self
    def sync_folder
      read_config['sync_folder']
    end

    def sync_folder=(path)
      config = read_config
      config['sync_folder'] = path.presence
      write_config(config)
    end

    def enabled?
      folder = sync_folder
      folder.present? && Dir.exist?(folder)
    end

    def last_synced_at
      ts = read_config['last_synced_at']
      ts ? Time.parse(ts) : nil
    rescue ArgumentError
      nil
    end

    def last_synced_at=(time)
      config = read_config
      config['last_synced_at'] = time&.iso8601
      write_config(config)
    end

    private

    def read_config
      return {} unless File.exist?(CONFIG_PATH)

      JSON.parse(File.read(CONFIG_PATH))
    rescue JSON::ParserError
      {}
    end

    def write_config(config)
      FileUtils.mkdir_p(File.dirname(CONFIG_PATH))
      File.write(CONFIG_PATH, JSON.pretty_generate(config))
    end
  end
end
