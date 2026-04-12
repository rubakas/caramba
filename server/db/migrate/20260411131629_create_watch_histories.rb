class CreateWatchHistories < ActiveRecord::Migration[8.1]
  def change
    create_table :watch_histories do |t|
      t.references :episode, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :progress_seconds
      t.integer :duration_seconds

      t.timestamps
    end

    add_index :watch_histories, :episode_id
  end
end
