class AddTechMetadataToMedia < ActiveRecord::Migration[8.1]
  def change
    add_column :episodes, :tech_metadata, :text
    add_column :movies, :tech_metadata, :text
  end
end
