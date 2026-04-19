class CreatePendingImports < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_imports do |t|
      t.references :media_folder, null: false, foreign_key: { on_delete: :cascade }
      t.string :folder_path, null: false
      t.string :kind, null: false
      t.string :parsed_name
      t.integer :parsed_year
      t.text :candidates
      t.string :status, null: false, default: "pending"
      t.string :chosen_external_id
      t.text :error
      t.timestamps
    end
    add_index :pending_imports, :folder_path, unique: true
    add_index :pending_imports, :status
  end
end
