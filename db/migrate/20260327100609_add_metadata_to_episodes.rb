class AddMetadataToEpisodes < ActiveRecord::Migration[8.1]
  def change
    add_column :episodes, :description, :text
    add_column :episodes, :air_date, :string
    add_column :episodes, :runtime, :integer
    add_column :episodes, :tvmaze_id, :integer
  end
end
