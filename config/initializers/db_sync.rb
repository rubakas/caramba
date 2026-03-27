# Database sync on startup (check only — no periodic thread).
#
# On boot, if a sync folder is configured, compare timestamps and load
# whichever DB is newer. Periodic sync is NOT auto-started here — the
# user must explicitly enable it from Settings > Database Sync.
#
# The sync config is stored in storage/sync_config.json (outside the DB)
# so it survives DB replacements.

Rails.application.config.after_initialize do
  # Only run in server mode (not console, rake tasks, etc.)
  next unless defined?(Rails::Server) || ENV['SYNC_ON_BOOT'] == '1'

  if SyncConfig.enabled?
    Rails.logger.info("DbSync: sync folder configured — #{SyncConfig.sync_folder}")

    # Load newer DB from sync folder if available
    DbSync.sync_on_startup!

    # NOTE: periodic sync is NOT started automatically. The user starts it
    # from the Settings page (SettingsController#update). This avoids
    # unintended DB replacements during development.
  else
    Rails.logger.info('DbSync: no sync folder configured, skipping')
  end
end

# Stop the sync thread gracefully on shutdown (if user started it from Settings)
at_exit do
  DbSync.stop_periodic_sync! if DbSync.sync_running?
end
