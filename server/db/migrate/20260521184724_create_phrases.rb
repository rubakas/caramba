class CreatePhrases < ActiveRecord::Migration[8.1]
  def change
    create_table :phrases do |t|
      t.references :lesson, null: false, foreign_key: { on_delete: :cascade }
      t.integer :position, null: false

      t.text :phrase, null: false
      t.text :translation
      t.text :meaning

      t.integer :start_ms, null: false
      t.integer :end_ms, null: false

      # Per-phrase clip lifecycle. Phase 3 wires extraction.
      t.string :clip_path
      t.string :clip_status, null: false, default: "pending"
      t.text :clip_error

      t.timestamps
    end
    add_index :phrases, [ :lesson_id, :position ], unique: true
  end
end
