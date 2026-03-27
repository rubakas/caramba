class CreateMovies < ActiveRecord::Migration[8.1]
  def change
    create_table :movies do |t|
      t.string  :title,            null: false
      t.string  :slug,             null: false
      t.string  :file_path,        null: false
      t.boolean :watched,          default: false
      t.datetime :last_watched_at
      t.integer :progress_seconds, default: 0
      t.integer :duration_seconds, default: 0

      # OMDb metadata
      t.string  :poster_url
      t.text    :description
      t.string  :year
      t.string  :genres
      t.float   :rating
      t.integer :runtime
      t.string  :imdb_id
      t.string  :director

      t.timestamps
    end

    add_index :movies, :slug, unique: true
    add_index :movies, :file_path, unique: true
  end
end
