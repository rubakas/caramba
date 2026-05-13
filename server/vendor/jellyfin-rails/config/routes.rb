Jellyfin::Rails::Engine.routes.draw do
  get  '_status', to: 'status#show'
  get  'probe',   to: 'probe#show'

  post 'playback_info', to: 'playback_info#create', as: :playback_info
  get  'playback_info', to: 'playback_info#show',   as: :playback_info_get
  get  'playback/bitrate_test', to: 'bitrate_test#show', as: :bitrate_test
  delete 'videos/active_encodings', to: 'active_encodings#destroy', as: :stop_encoding

  scope 'transcode' do
    post 'start',                  to: 'transcoding#start',   as: :start
    # HEAD support on master/variant/segment mirrors upstream DynamicHls.cs
    # `[HttpHead]` annotations so clients can probe headers before fetching.
    match ':token/master.m3u8',     to: 'transcoding#master',  via: %i[get head], as: :master
    match ':token/main.m3u8',       to: 'transcoding#variant', via: %i[get head], as: :variant
    match ':token/:segment.ts',     to: 'transcoding#segment', via: %i[get head], as: :segment, constraints: { segment: /\d+/ }
    match ':token/abr_master.m3u8', to: 'abr#master',          via: %i[get head], as: :abr_master
    get   ':token/progress',        to: 'progress#show',       as: :progress
  end

  match 'stream/:token',                        to: 'stream#show',   via: %i[get head], as: :stream
  match 'stream/:token/remux.:container',       to: 'remux#show',    via: %i[get head], as: :remux,
      constraints: { container: /mp4|mkv|webm|ts/ }
  get 'download/:token',                      to: 'download#show', as: :download

  get 'subtitles/:token/:index.:format', to: 'subtitles#show', as: :subtitle,
      constraints: { index: /\d+/, format: /vtt|srt|ass/ }
  # GetSubtitleWithTicks (upstream SubtitleController.cs:298). Same extraction
  # as `:subtitle` but trims cues to the requested [start, end] ticks.
  get 'subtitles/:token/:index/:start_position_ticks.:format',
      to: 'subtitles#with_ticks', as: :subtitle_with_ticks,
      constraints: { index: /\d+/, start_position_ticks: /\d+/, format: /vtt|srt|ass/ }

  # Fallback font (upstream SubtitleController.cs:548).
  get 'fallback_fonts/:name', to: 'fallback_fonts#show', as: :fallback_font,
      constraints: { name: /[\w.\-]+/ }

  scope 'webvtt' do
    get ':token/:stream_index/index.m3u8',  to: 'webvtt_subs#index', as: :webvtt_index,
        constraints: { stream_index: /\d+/ }
    get ':token/:stream_index/:segment.vtt', to: 'webvtt_subs#segment', as: :webvtt_segment,
        constraints: { stream_index: /\d+/, segment: /\d+/ }
  end

  scope 'live_streams' do
    post 'open',   to: 'live_streams#open',   as: :live_stream_open
    post 'close',  to: 'live_streams#close',  as: :live_stream_close
    get  'active', to: 'live_streams#active', as: :live_streams_active
  end

  scope 'trickplay' do
    get ':token/:width/index.m3u8',  to: 'trickplay#index', as: :trickplay_index,
        constraints: { width: /\d+/ }
    get ':token/:width/:index.jpg',  to: 'trickplay#tile',  as: :trickplay_tile,
        constraints: { width: /\d+/, index: /\d+/ }
  end

  get 'audio/:token/universal.:container', to: 'universal_audio#show', as: :universal_audio,
      constraints: { container: /mp3|aac|flac|m4a|opus|ogg/ }

  # Progressive video streaming (ports of VideosController.cs GetVideoStream
  # and GetVideoStreamByContainer). Match also accepts HEAD per upstream.
  match 'videos/:token/stream',                        to: 'videos#stream', via: %i[get head], as: :video_stream, format: false
  match 'videos/:token/stream.:container',             to: 'videos#stream', via: %i[get head], as: :video_stream_by_container, format: false,
        constraints: { container: /mp4|mkv|webm|ts/ }

  # Progressive audio streaming (ports of AudioController.cs).
  match 'audio_stream/:token/stream',                  to: 'audio_stream#stream', via: %i[get head], as: :audio_progressive, format: false
  match 'audio_stream/:token/stream.:container',       to: 'audio_stream#stream', via: %i[get head], as: :audio_progressive_by_container, format: false,
        constraints: { container: /mp3|aac|flac|m4a|opus|ogg|wav/ }

  # Audio HLS pipeline (ports of DynamicHlsController.GetMasterHlsAudioPlaylist,
  # GetVariantHlsAudioPlaylist, GetHlsAudioSegment).
  scope 'audio_hls' do
    match ':token/master.m3u8',         to: 'audio_hls#master',  via: %i[get head], as: :audio_hls_master, format: false
    match ':token/main.m3u8',           to: 'audio_hls#variant', via: %i[get head], as: :audio_hls_variant, format: false
    match ':token/:segment.:container', to: 'audio_hls#segment', via: %i[get head], as: :audio_hls_segment, format: false,
          constraints: { segment: /\d+/, container: /aac|m4s|mp4|ts/ }
  end

  # Live HLS playlist (port of DynamicHlsController.GetLiveHlsStream).
  match 'live_hls/:token/live.m3u8', to: 'live_hls#show', via: %i[get head], as: :live_hls, format: false

  get 'images/:token/:type', to: 'images#show', as: :image,
      constraints: { type: /primary|backdrop|logo|banner|art|chapter/ }

  scope 'sessions' do
    post 'playing',          to: 'sessions#playing',  as: :session_playing
    post 'playing/progress', to: 'sessions#progress', as: :session_progress
    post 'playing/stopped',  to: 'sessions#stopped',  as: :session_stopped
    post 'playing/ping',     to: 'sessions#ping',     as: :session_ping
    get  'active',           to: 'sessions#active',   as: :sessions_active
  end

  get 'keys/:token/:fingerprint.key', to: 'keys#show', as: :encryption_key,
      constraints: { fingerprint: /[a-f0-9]+/ }
end
