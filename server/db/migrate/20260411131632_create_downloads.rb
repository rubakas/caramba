class CreateDownloads < ActiveRecord::Migration[8.1]
  def change
    create_table :downloads do |t|
      t.references :episode, foreign_key: { on_delete: :cascade }, index: false
      t.references :movie, foreign_key: { on_delete: :cascade }, index: false
      t.string :file_path, null: false
      t.integer :file_size, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.float :progress, null: false, default: 0
      t.datetime :created_at, null: false
    end

    add_index :downloads, :episode_id, unique: true, where: "episode_id IS NOT NULL"
    add_index :downloads, :movie_id, unique: true, where: "movie_id IS NOT NULL"

    add_check_constraint :downloads,
      "(episode_id IS NOT NULL AND movie_id IS NULL) OR (episode_id IS NULL AND movie_id IS NOT NULL)",
      name: "downloads_episode_or_movie"
  end
end
