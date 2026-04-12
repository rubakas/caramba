class CreateSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :series do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :media_path
      t.text :description
      t.string :poster_url
      t.integer :tvmaze_id
      t.string :imdb_id
      t.string :genres
      t.float :rating
      t.string :premiered
      t.string :status

      t.timestamps
    end

    add_index :series, :slug, unique: true
  end
end
