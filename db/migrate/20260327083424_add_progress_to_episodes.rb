class AddProgressToEpisodes < ActiveRecord::Migration[8.1]
  def change
    add_column :episodes, :progress_seconds, :integer, default: 0
    add_column :episodes, :duration_seconds, :integer, default: 0
  end
end
