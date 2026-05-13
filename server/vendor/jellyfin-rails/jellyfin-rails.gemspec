require_relative 'lib/jellyfin/rails/version'

Gem::Specification.new do |spec|
  spec.name        = 'jellyfin-rails'
  spec.version     = Jellyfin::Rails::VERSION
  spec.authors     = ['Vladyslav']
  spec.email       = ['vladyslav@hey.com']

  spec.summary     = 'Path-based media transcoding and a customizable web player as a Rails engine'
  spec.description = <<~DESC
    A Rails engine that ports Jellyfin's transcoding pipeline (EncodingHelper, MediaEncoder,
    TranscodeManager) to Ruby and pairs it with @jellyfin-rails/player, an npm package extracted
    from jellyfin-web's htmlVideoPlayer. The host Rails application owns library scanning,
    users, and UI; this gem owns ffmpeg orchestration and playback.
  DESC
  spec.homepage    = 'https://github.com/cupatea/jellyfin-rails'
  spec.license     = 'GPL-2.0'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir[
      'lib/**/*',
      'app/**/*',
      'config/**/*',
      'README.md',
      'LICENSE',
      'jellyfin-rails.gemspec'
    ]
  end
  spec.require_paths = ['lib']

  spec.add_dependency 'rails', '>= 7.1', '< 9.0'
end
