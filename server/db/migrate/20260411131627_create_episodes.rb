class CreateEpisodes < ActiveRecord::Migration[8.1]
  def change
    create_table :episodes do |t|
      t.references :series, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :code, null: false
      t.string :title
      t.integer :season_number
      t.integer :episode_number
      t.string :file_path
      t.string :air_date
      t.text :description
      t.integer :runtime
      t.integer :tvmaze_id
      t.integer :watched, null: false, default: 0
      t.integer :progress_seconds, null: false, default: 0
      t.integer :duration_seconds, null: false, default: 0
      t.datetime :last_watched_at

      t.timestamps
    end

    add_index :episodes, [ :series_id, :code ], unique: true
    add_index :episodes, :series_id
  end
end
