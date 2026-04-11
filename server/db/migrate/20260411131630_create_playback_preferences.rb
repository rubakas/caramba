class CreatePlaybackPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :playback_preferences do |t|
      t.references :series, foreign_key: { on_delete: :cascade }, index: false
      t.references :movie, foreign_key: { on_delete: :cascade }, index: false
      t.string :audio_language
      t.string :subtitle_language
      t.integer :subtitle_off, null: false, default: 0
      t.string :subtitle_size, null: false, default: "medium"
      t.string :subtitle_style, null: false, default: "classic"

      t.timestamps
    end

    add_index :playback_preferences, :series_id, unique: true
    add_index :playback_preferences, :movie_id, unique: true
  end
end
