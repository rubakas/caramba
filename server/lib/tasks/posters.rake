namespace :posters do
  desc "Download and attach posters for all Series, Movies and Watchlist items that have a poster_url but no attached image yet"
  task backfill: :environment do
    [ Series, Movie, Watchlist ].each do |klass|
      records = klass.where.not(poster_url: [ nil, "" ]).includes(:poster_attachment)
      total = records.count
      done = 0
      skipped = 0
      failed = 0

      puts "\n#{klass}: #{total} record(s) with a poster_url"

      records.find_each do |record|
        if record.poster.attached?
          skipped += 1
          next
        end

        if record.download_poster!
          done += 1
          print "."
        else
          failed += 1
          print "F"
        end
      end

      puts "\n#{klass}: downloaded=#{done}, skipped=#{skipped}, failed=#{failed}"
    end
  end
end
