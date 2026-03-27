class CreateEpisodes < ActiveRecord::Migration[8.1]
  def change
    create_table :episodes do |t|
      t.string :code
      t.integer :season_number
      t.integer :episode_number
      t.string :title
      t.string :file_path
      t.boolean :watched, default: false, null: false
      t.datetime :last_watched_at

      t.timestamps
    end
    add_index :episodes, :code, unique: true
  end
end
