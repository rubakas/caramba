class ScopeMediaFoldersUniquenessToKind < ActiveRecord::Migration[8.1]
  def change
    remove_index :media_folders, :path
    add_index :media_folders, [ :path, :kind ], unique: true
  end
end
