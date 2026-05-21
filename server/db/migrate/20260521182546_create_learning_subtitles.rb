class CreateLearningSubtitles < ActiveRecord::Migration[8.1]
  def change
    create_table :learning_subtitles do |t|
      t.references :media, polymorphic: true, null: false, index: false
      t.integer :stream_index, null: false
      t.string :language
      t.string :format, null: false
      t.string :path, null: false
      t.integer :byte_size, default: 0, null: false
      t.datetime :extracted_at, null: false
      t.timestamps
    end
    add_index :learning_subtitles, [ :media_type, :media_id, :stream_index ],
              unique: true, name: "index_learning_subtitles_on_media_and_stream"
    add_index :learning_subtitles, [ :media_type, :media_id ],
              name: "index_learning_subtitles_on_media"
  end
end
