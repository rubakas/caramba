# jellyfin-rails

Path-based media transcoding and a customizable web player, as a Rails engine.
The host Rails application owns library scanning, users, and UI; this gem owns
ffmpeg orchestration and playback.

- **Gem:** `jellyfin-rails` (this repo) — Rails engine, Ruby port of Jellyfin's
  `MediaBrowser.MediaEncoding` (EncodingHelper / TranscodeManager / Probe).
- **npm:** `@jellyfin-rails/player` — extensible web video player extracted
  from `jellyfin-web`'s `htmlVideoPlayer`.

License: **GPL-2.0** (derivative work of [Jellyfin](https://github.com/jellyfin/jellyfin)
and [jellyfin-web](https://github.com/jellyfin/jellyfin-web)).

## Install

### 1. Add the gem

```ruby
# Gemfile
gem 'jellyfin-rails'
```

```sh
bundle install
rails g jellyfin:install
```

The generator writes `config/initializers/jellyfin.rb` and mounts the engine in
`config/routes.rb`.

### 2. Install jellyfin-ffmpeg

This gem doesn't vendor ffmpeg — you install Jellyfin's patched ffmpeg build
separately. Stock ffmpeg works but loses HDR tone mapping and most HW accel.

| OS | Install |
|---|---|
| macOS | Install Jellyfin.app from https://jellyfin.org/downloads — ffmpeg is bundled at `/Applications/Jellyfin.app/Contents/MacOS/ffmpeg` |
| Debian/Ubuntu | `curl https://repo.jellyfin.org/install-debuntu.sh \| sudo bash && sudo apt install jellyfin-ffmpeg7` |
| RHEL/Fedora | Install the `jellyfin-ffmpeg7` rpm from https://repo.jellyfin.org |
| Docker | Use `jellyfin/jellyfin` as a base, or install `jellyfin-ffmpeg7` in your image |

Update `c.ffmpeg_path` and `c.ffprobe_path` in the initializer to point at the
installed binaries.

### 3. Install the player package

```sh
npm install @jellyfin-rails/player hls.js
```

In your application JavaScript:

```js
import '@jellyfin-rails/player';   // auto-registers <jellyfin-player>
```

For ASS/SSA or PGS subtitle rendering, also install:

```sh
npm install @jellyfin/libass-wasm libpgs
```

## Use

```erb
<%# app/views/videos/show.html.erb %>
<%= jellyfin_player(path: @video.file_path,
                    autoplay: true,
                    max_height: 1080,
                    reporter_url: api_progress_path(@video)) do |p| %>
  <% p.slot :overlay_top do %><%= render 'header' %><% end %>
  <% p.slot :controls_right do %><%= render 'cast_button' %><% end %>
<% end %>
```

That single helper:
1. Verifies the path is inside `allowed_paths` (403 otherwise).
2. Signs a transcode token with HMAC.
3. Renders `<jellyfin-player src="/jellyfin/transcode/:token/master.m3u8">` with
   any host-supplied slot content.

The browser receives a working HLS player; the server-side ffmpeg process spawns
on the first segment request and shuts itself down after `idle_timeout`.

## API endpoints (engine routes)

```
GET  /jellyfin/_status                                  ffmpeg version + capabilities
GET  /jellyfin/probe?path=/srv/media/x.mkv              MediaSourceInfo JSON
POST /jellyfin/transcode/start                          → token + master URL
GET  /jellyfin/transcode/:token/master.m3u8             HLS playlist
GET  /jellyfin/transcode/:token/:n.ts                   HLS segment
GET  /jellyfin/subtitles/:token/:index.vtt              extracted subtitle
```

## Player extension hooks

```ts
import { Player } from '@jellyfin-rails/player';

const player = new Player(container, {
  source: { hlsUrl: '/jellyfin/transcode/abc/master.m3u8' },

  // 1. Custom track provider — host supplies subtitle/audio/chapter metadata.
  trackProvider: {
    getSubtitleTracks: () => [{ id: 1, url: '/subs/en.vtt', language: 'en' }],
    getChapters: () => fetch('/chapters/42').then(r => r.json())
  },

  // 2. Reporter — host stores progress wherever it wants.
  reporter: {
    onStart:    s => fetch('/progress/start',    { method: 'POST', body: JSON.stringify(s) }),
    onProgress: s => fetch('/progress/progress', { method: 'POST', body: JSON.stringify(s) }),
    onStop:     s => fetch('/progress/stop',     { method: 'POST', body: JSON.stringify(s) })
  }
});

// 3. Event bus — subscribe to any playback event.
player.on('progress', ({ currentTime, duration }) => { /* ... */ });

// 4. Slots — mount any DOM into named regions.
player.mountSlot('controls-right', myCastButton);

await player.load();
```

## Architecture

```
jellyfin-rails/                         # Rails engine
├── lib/jellyfin/
│   ├── encoding/         # Ruby port of MediaBrowser.MediaEncoding
│   │   ├── encoding_helper.rb      # ffmpeg arg generation
│   │   ├── codec_selector.rb       # h264/h265/av1/aac selection
│   │   ├── bitrate.rb              # bitrate / channel calculations
│   │   ├── filters/                # scale, tonemap, subtitle burn
│   │   └── hwaccel/                # videotoolbox / vaapi / nvenc / qsv
│   ├── media_encoder/    # ffmpeg / ffprobe wrappers + capability probe
│   ├── probing/          # MediaSourceInfo + MediaStream PODs
│   └── transcoding/      # TranscodeManager, signed tokens, segment cache
├── app/controllers/jellyfin/
│   ├── status, probe, transcoding, subtitles
└── app/helpers/jellyfin/player_helper.rb

packages/player/                        # npm: @jellyfin-rails/player
├── src/
│   ├── player.ts         # core class + lifecycle
│   ├── event-bus.ts      # typed event emitter
│   ├── element.ts        # <jellyfin-player> custom element
│   ├── subtitles/        # libass + libpgs + native dispatchers
│   └── extensions/       # slots, track-provider, reporter
```

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Skeleton, CI, status endpoint | done |
| 1 | ffprobe wrapper, MediaSourceInfo, /probe | done |
| 2 | TranscodeManager, signed tokens, /transcode/* | done |
| 3 | Player MVP, view helper, custom element | done |
| 4 | Event bus, slots, track provider, reporter, libass/libpgs | done |
| 5 | EncodingHelper SW paths (codec, bitrate, scale, tonemap, subtitle burn) | done |
| 6 | EncodingHelper HW accel (VideoToolbox / VAAPI / NVENC / QSV) | done |
| 7 | Polish, generators, docs | in progress |

See `/Users/cupatea/.claude/plans/make-plan-you-can-bright-seahorse.md` for the
full 19-week plan and risks (upstream drift, snapshot testing against C#, etc.).

## Compatibility

- Ruby 3.2+ (tested on 3.2, 3.3, 4.0)
- Rails 7.1, 7.2, 8.0
- jellyfin-ffmpeg 7.x (also works with stock ffmpeg 6+ with reduced features)

## License

GPL-2.0. The Ruby port of `EncodingHelper` and the extracted `htmlVideoPlayer`
are derivative works of GPL-2.0 software and inherit the same license.

Host Rails applications using this gem through the standard `require` boundary
are not derivative works of GPL-2.0 code (they communicate through a stable
program interface). Apps that copy or modify the gem's source are.
