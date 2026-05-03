# Parses movie names and years from filenames.
#
# Thin facade over FilenameParserService — kept for callers that only
# need the two helpers below. New code should call FilenameParserService
# directly to also get provider IDs, extras detection, etc.

class MovieParserService
  class << self
    def name_from_filename(filepath)
      FilenameParserService.name_from_filename(filepath)
    end

    def year_from_filename(filepath)
      FilenameParserService.year_from_filename(filepath)
    end
  end
end
