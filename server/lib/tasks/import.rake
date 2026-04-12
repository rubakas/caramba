# Import data from desktop's SQLite database into the Rails server database.
#
# Usage:
#   cd server
#   bin/rails db:import SOURCE=/path/to/desktop/storage/development.sqlite3
#
# The server database must already be migrated (bin/rails db:setup).
# Existing data is wiped before import.

namespace :db do
  desc "Import data from desktop SQLite database"
  task import: :environment do
    source = ENV["SOURCE"]
    abort "Usage: bin/rails db:import SOURCE=/path/to/development.sqlite3" unless source
    abort "Source file not found: #{source}" unless File.exist?(source)

    require "sqlite3"

    src = SQLite3::Database.new(source)
    src.results_as_hash = true

    # Order matters: foreign keys
    tables = %w[series episodes movies watch_histories playback_preferences watchlist downloads]

    ActiveRecord::Base.transaction do
      # Disable foreign key checks during import
      ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = OFF")

      # Wipe existing data in reverse order
      tables.reverse_each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end

      tables.each do |table|
        rows = src.execute("SELECT * FROM #{table}")
        next if rows.empty?

        columns = rows.first.keys.select { |k| k.is_a?(String) }
        puts "Importing #{table}: #{rows.size} rows..."

        rows.each do |row|
          values = columns.map { |c| row[c] }
          placeholders = columns.map { "?" }.join(", ")
          quoted_columns = columns.map { |c| %("#{c}") }.join(", ")
          sql = "INSERT INTO #{table} (#{quoted_columns}) VALUES (#{placeholders})"
          ActiveRecord::Base.connection.execute(
            ActiveRecord::Base.sanitize_sql_array([ sql, *values ])
          )
        end
      end

      # Re-enable foreign key checks
      ActiveRecord::Base.connection.execute("PRAGMA foreign_keys = ON")
    end

    src.close
    puts "Done."
  end
end
