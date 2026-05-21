class CreateLessons < ActiveRecord::Migration[8.1]
  def change
    create_table :lessons do |t|
      # Lesson belongs to either an Episode or a Movie (mutually exclusive).
      # Following the Downloads convention of split nullable columns rather
      # than a polymorphic association — keeps the joins simple.
      t.references :episode, null: true, foreign_key: { on_delete: :cascade }
      t.references :movie,   null: true, foreign_key: { on_delete: :cascade }

      # The subtitle file the lesson was generated from.
      t.references :source_subtitle, null: false, foreign_key: { to_table: :learning_subtitles, on_delete: :cascade }

      t.string :status, null: false, default: "pending"
      t.text :error

      # Generation provenance — `manual` for MVP, later anthropic/openai/ollama.
      t.string :provider, null: false, default: "manual"
      t.string :model
      t.integer :prompt_version, null: false, default: 1

      t.string :target_language, null: false, default: "uk"
      t.string :source_language, null: false, default: "en"

      t.timestamps
    end
    add_index :lessons, :status
  end
end
