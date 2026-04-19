class CreateMediaFolders < ActiveRecord::Migration[8.1]
  def change
    create_table :media_folders do |t|
      t.string :path, null: false
      t.string :kind, null: false
      t.boolean :enabled, null: false, default: true
      t.datetime :last_scanned_at
      t.timestamps
    end
    add_index :media_folders, :path, unique: true
  end
end
