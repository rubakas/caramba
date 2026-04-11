class CreateWatchlist < ActiveRecord::Migration[8.1]
  def change
    create_table :watchlist do |t|
      t.string :type, null: false, default: "show"
      t.integer :tvmaze_id
      t.string :name, null: false
      t.string :poster_url
      t.text :description
      t.string :genres
      t.float :rating
      t.string :premiered
      t.string :status
      t.string :network
      t.string :imdb_id
      t.string :year
      t.string :director
      t.integer :runtime

      t.timestamps
    end

    add_index :watchlist, :tvmaze_id, unique: true, where: "tvmaze_id IS NOT NULL"
    add_index :watchlist, :imdb_id, unique: true, where: "imdb_id IS NOT NULL"
  end
end
