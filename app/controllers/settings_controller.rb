class SettingsController < ApplicationController
  def show
    @sync_folder = SyncConfig.sync_folder
    @status = DbSync.status
  end

  def update
    folder = params[:sync_folder]&.strip

    if folder.present? && !Dir.exist?(folder)
      redirect_to settings_path, alert: "Folder does not exist: #{folder}"
      return
    end

    SyncConfig.sync_folder = folder

    if folder.present?
      # Start sync: do initial dump, then start periodic
      DbSync.dump!
      DbSync.start_periodic_sync!
      redirect_to settings_path, notice: 'Sync folder set. Database will sync every 30 seconds.'
    else
      # Disabled sync
      DbSync.stop_periodic_sync!
      redirect_to settings_path, notice: 'Sync disabled.'
    end
  end

  def sync_now
    if SyncConfig.enabled?
      DbSync.dump!
      redirect_to settings_path, notice: 'Database synced to folder.'
    else
      redirect_to settings_path, alert: 'No sync folder configured.'
    end
  end

  def load_from_sync
    if SyncConfig.enabled? && File.exist?(File.join(SyncConfig.sync_folder, DbSync::SYNC_FILENAME))
      DbSync.load!
      redirect_to settings_path, notice: 'Database loaded from sync folder.'
    else
      redirect_to settings_path, alert: 'No database found in sync folder.'
    end
  end
end
