class CreateMovies < ActiveRecord::Migration[8.1]
  def change
    create_table :movies do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.string :file_path
      t.string :year
      t.text :description
      t.string :poster_url
      t.string :imdb_id
      t.string :genres
      t.float :rating
      t.string :director
      t.integer :runtime
      t.integer :watched, default: 0
      t.integer :progress_seconds, null: false, default: 0
      t.integer :duration_seconds, null: false, default: 0
      t.datetime :last_watched_at

      t.timestamps
    end

    add_index :movies, :slug, unique: true
    add_index :movies, :file_path, unique: true
  end
end
