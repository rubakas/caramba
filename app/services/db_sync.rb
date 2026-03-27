# Handles database synchronization between instances via a shared folder.
#
# The sync folder contains a copy of the SQLite database file. On startup,
# the app compares local vs sync timestamps and loads whichever is newer
# (last-write wins). Periodically, the local DB is dumped to the sync folder.
#
# Usage:
#   DbSync.dump!                 # copy local DB → sync folder
#   DbSync.load!                 # copy sync folder DB → local (reconnects AR)
#   DbSync.sync_on_startup!      # load newer DB if sync folder has one
#   DbSync.start_periodic_sync!  # start background thread (every 30s)
#   DbSync.stop_periodic_sync!   # stop the background thread
#
class DbSync
  SYNC_FILENAME = 'series_tracker.sqlite3'.freeze
  SYNC_INTERVAL = 30 # seconds

  class << self
    # Copy local database to the sync folder.
    def dump!
      return false unless SyncConfig.enabled?

      src = local_db_path
      dst = sync_db_path

      return false unless File.exist?(src)

      # Use SQLite backup API via command line for safe copy while DB is open
      # This avoids copying a partially-written file
      tmp = "#{dst}.tmp"
      system('sqlite3', src, ".backup '#{tmp}'")

      if File.exist?(tmp) && File.size(tmp) > 0
        FileUtils.mv(tmp, dst)
        SyncConfig.last_synced_at = Time.current
        Rails.logger.info("DbSync: dumped database to #{dst}")
        true
      else
        FileUtils.rm_f(tmp)
        Rails.logger.warn('DbSync: backup command produced empty file')
        false
      end
    rescue StandardError => e
      Rails.logger.warn("DbSync: dump failed — #{e.message}")
      false
    end

    # Load database from sync folder, replacing the local one.
    # Reconnects ActiveRecord after replacing the file.
    def load!
      return false unless SyncConfig.enabled?

      src = sync_db_path
      dst = local_db_path

      return false unless File.exist?(src)

      # Disconnect ActiveRecord so we can replace the file
      ActiveRecord::Base.connection_pool.disconnect!

      # Backup current local DB just in case
      backup = "#{dst}.backup"
      FileUtils.cp(dst, backup) if File.exist?(dst)

      # Copy sync DB to local
      FileUtils.cp(src, dst)

      # Reconnect ActiveRecord
      ActiveRecord::Base.establish_connection
      ActiveRecord::Base.connection # force connect

      # Run any pending migrations (in case the other instance has an older schema)
      ActiveRecord::MigrationContext.new(Rails.root.join('db', 'migrate')).migrate

      SyncConfig.last_synced_at = Time.current
      Rails.logger.info("DbSync: loaded database from #{src}")

      # Clean up backup
      FileUtils.rm_f(backup)
      true
    rescue StandardError => e
      Rails.logger.warn("DbSync: load failed — #{e.message}")
      # Try to restore from backup
      begin
        backup = "#{dst}.backup"
        if File.exist?(backup)
          FileUtils.cp(backup, dst)
          ActiveRecord::Base.establish_connection
          Rails.logger.info('DbSync: restored local DB from backup after failed load')
        end
      rescue StandardError
        # nothing we can do
      end
      false
    end

    # On startup: if sync folder has a newer DB, load it.
    # Otherwise, dump our local DB to sync folder.
    def sync_on_startup!
      return unless SyncConfig.enabled?

      local = local_db_path
      remote = sync_db_path

      local_mtime  = File.exist?(local) ? File.mtime(local) : Time.at(0)
      remote_mtime = File.exist?(remote) ? File.mtime(remote) : Time.at(0)

      if File.exist?(remote) && remote_mtime > local_mtime
        Rails.logger.info("DbSync: sync folder has newer DB (#{remote_mtime} vs #{local_mtime}), loading...")
        load!
      elsif File.exist?(local)
        Rails.logger.info('DbSync: local DB is current, dumping to sync folder...')
        dump!
      end
    rescue StandardError => e
      Rails.logger.warn("DbSync: startup sync failed — #{e.message}")
    end

    # Start a background thread that periodically dumps the DB.
    # Also checks if the sync copy is newer (another instance wrote to it).
    def start_periodic_sync!
      return unless SyncConfig.enabled?

      stop_periodic_sync! # ensure no duplicate threads

      @sync_thread = Thread.new do
        Rails.logger.info("DbSync: periodic sync started (every #{SYNC_INTERVAL}s)")
        loop do
          sleep SYNC_INTERVAL
          break if @stop_sync

          begin
            # Check if sync copy is newer (another instance pushed an update)
            local_mtime  = File.exist?(local_db_path) ? File.mtime(local_db_path) : Time.at(0)
            remote_mtime = File.exist?(sync_db_path) ? File.mtime(sync_db_path) : Time.at(0)

            if File.exist?(sync_db_path) && remote_mtime > local_mtime + 2
              Rails.logger.info('DbSync: sync folder has newer DB, loading...')
              load!
            else
              dump!
            end
          rescue StandardError => e
            Rails.logger.warn("DbSync: periodic sync error — #{e.message}")
          end
        end
        Rails.logger.info('DbSync: periodic sync stopped')
      end

      @sync_thread.abort_on_exception = false
    end

    def stop_periodic_sync!
      @stop_sync = true
      @sync_thread&.join(5)
      @sync_thread = nil
      @stop_sync = false
    end

    def sync_running?
      @sync_thread&.alive? || false
    end

    # Info hash for the settings page
    def status
      local = local_db_path
      remote = SyncConfig.sync_folder ? sync_db_path : nil

      {
        enabled: SyncConfig.enabled?,
        sync_folder: SyncConfig.sync_folder,
        local_db: local,
        local_mtime: File.exist?(local) ? File.mtime(local) : nil,
        local_size: File.exist?(local) ? File.size(local) : nil,
        remote_db: remote,
        remote_exists: remote ? File.exist?(remote) : false,
        remote_mtime: remote && File.exist?(remote) ? File.mtime(remote) : nil,
        remote_size: remote && File.exist?(remote) ? File.size(remote) : nil,
        last_synced_at: SyncConfig.last_synced_at,
        sync_running: sync_running?
      }
    end

    private

    def local_db_path
      db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first
      db_path = db_config.database
      # Resolve relative paths
      db_path.start_with?('/') ? db_path : Rails.root.join(db_path).to_s
    end

    def sync_db_path
      File.join(SyncConfig.sync_folder, SYNC_FILENAME)
    end
  end
end
