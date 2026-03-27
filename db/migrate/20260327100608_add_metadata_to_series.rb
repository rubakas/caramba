class AddMetadataToSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :series, :description, :text
    add_column :series, :genres, :string
    add_column :series, :rating, :float
    add_column :series, :premiered, :string
    add_column :series, :status, :string
    add_column :series, :tvmaze_id, :integer
    add_column :series, :imdb_id, :string
  end
end
