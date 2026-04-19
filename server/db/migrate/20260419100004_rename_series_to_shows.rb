class RenameSeriesToShows < ActiveRecord::Migration[8.1]
  def change
    rename_table :series, :shows

    rename_column :episodes, :series_id, :show_id
    rename_index :episodes, "index_episodes_on_series_id", "index_episodes_on_show_id"
    rename_index :episodes, "index_episodes_on_series_id_and_code", "index_episodes_on_show_id_and_code"

    rename_column :playback_preferences, :series_id, :show_id
    rename_index :playback_preferences, "index_playback_preferences_on_series_id", "index_playback_preferences_on_show_id"

    rename_index :shows, "index_series_on_slug", "index_shows_on_slug"

    # Update any existing kind enum values for media folders / pending imports
    execute "UPDATE media_folders SET kind = 'shows' WHERE kind = 'series'"
    execute "UPDATE pending_imports SET kind = 'shows' WHERE kind = 'series'"
  end
end
