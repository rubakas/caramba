class CreateSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :series do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :media_path, null: false
      t.string :poster_url

      t.timestamps
    end

    add_index :series, :slug, unique: true
  end
end
