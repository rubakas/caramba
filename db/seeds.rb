# Seeds are now handled through the UI (Add Series form).
# To pre-seed The Simpsons from the command line:
#
#   MediaScanner.add_from_path!("/Volumes/Mac Backup/The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob")
#
# Or add any other series:
#
#   MediaScanner.add_from_path!("/path/to/Breaking.Bad.2008.1080p.BluRay.x265")
#

simpsons_path = ENV.fetch('SIMPSONS_MEDIA_PATH',
                          '/Volumes/Mac Backup/The.Simpsons.1989.WEBRip.BDRip.H.265-ernzarob')

MediaScanner.add_from_path!(simpsons_path) if Dir.exist?(simpsons_path) && Series.none?
