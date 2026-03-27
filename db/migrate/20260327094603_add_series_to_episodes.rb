class AddSeriesToEpisodes < ActiveRecord::Migration[8.1]
  def up
    # Add column as nullable first
    add_reference :episodes, :series, null: true, foreign_key: true

    # Migrate existing Simpsons episodes: create a Series record and assign them
    simpsons_path = ENV.fetch('SIMPSONS_MEDIA_PATH',
                              '/Volumes/Mac Backup/The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob')

    if Episode.any?
      series = execute(<<~SQL).first
        INSERT INTO series (name, slug, media_path, created_at, updated_at)
        VALUES ('The Simpsons', 'the-simpsons', '#{simpsons_path}', datetime('now'), datetime('now'))
        RETURNING id
      SQL

      execute("UPDATE episodes SET series_id = #{series['id']}")
    end

    # Now enforce NOT NULL
    change_column_null :episodes, :series_id, false

    # Replace global code uniqueness with series-scoped uniqueness
    remove_index :episodes, :code
    add_index :episodes, %i[series_id code], unique: true
  end

  def down
    remove_index :episodes, %i[series_id code]
    add_index :episodes, :code, unique: true
    remove_reference :episodes, :series
  end
end
