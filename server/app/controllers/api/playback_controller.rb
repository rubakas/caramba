class Api::PlaybackController < Api::BaseController
  # POST /api/playback/report_progress
  def report_progress
    time = params[:time].to_i
    duration = params[:duration].to_i
    return head(:unprocessable_entity) if duration <= 0

    if params[:episode_id].present?
      ep = Episode.find(params[:episode_id])
      ep.update_progress!(time, duration)

      if params[:watch_history_id].present?
        wh = WatchHistory.find(params[:watch_history_id])
        wh.update_progress!(time, duration)
      end

      ep.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
    end

    if params[:movie_id].present?
      movie = Movie.find(params[:movie_id])
      movie.update_progress!(time, duration)
      movie.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
    end

    render json: { absoluteTime: time, duration: duration }
  end

  # GET /api/playback/preferences?type=episode&show_id=1 or ?type=movie&movie_id=1
  def preferences
    pref = find_preference
    return render(json: nil) unless pref

    render json: {
      audioLanguage: pref.audio_language,
      audioCodec: pref.audio_codec,
      audioChannels: pref.audio_channels,
      subtitleLanguage: pref.subtitle_language,
      subtitleOff: pref.subtitle_off != 0,
      subtitleSize: pref.subtitle_size || "medium",
      subtitleStyle: pref.subtitle_style || "classic"
    }
  end

  # POST /api/playback/preferences
  def save_preferences
    if params[:type] == "episode" && params[:showId].present?
      pref = PlaybackPreference.find_or_initialize_by(show_id: params[:showId])
      pref.update!(preference_attrs)
    elsif params[:type] == "movie" && params[:movieId].present?
      pref = PlaybackPreference.find_or_initialize_by(movie_id: params[:movieId])
      pref.update!(preference_attrs)
    end

    render json: true
  end

  # POST /api/playback/start
  # Body: { filePath, startTime, prefs, deviceProfile }
  #
  # Resolves the playback URL the client should hit. Delegates probing,
  # strategy selection, token signing, and HLS orchestration to the
  # jellyfin-rails engine (mounted at /_jellyfin). Caramba keeps ownership of
  # track auto-selection (language/codec/channels precedence) and the
  # PlaybackPreference + WatchHistory bookkeeping around playback.
  def start
    file_path = params[:filePath]
    start_time = (params[:startTime] || 0).to_f
    prefs = params[:prefs]
    device_profile_raw = parse_device_profile(params[:deviceProfile])

    return render(json: { error: "filePath required" }, status: :unprocessable_entity) unless file_path.present?
    return render(json: { error: "File not found: #{file_path}" }, status: :unprocessable_entity) unless File.exist?(file_path)

    record = find_record_for(file_path)
    info = (record && TechProbeService.probe_for(record)) || TechProbeService.probe(file_path)
    return render(json: { error: "Probe failed" }, status: :unprocessable_entity) unless info

    audio_stream_index = select_audio_track(info[:audioStreams], prefs, device_profile_raw)
    subtitle_stream_index, is_bitmap = select_subtitle_track(info[:subtitleStreams], prefs, device_profile_raw)

    client_profile = CarambaClientProfile.build(device_profile_raw)
    media_source = Jellyfin::MediaEncoder::Probe.from_path(file_path)

    # Safety gate: HEVC/AV1 `:direct_stream` produces fMP4 segments cut on
    # SOURCE keyframes, so the variant playlist's `#EXTINF` values must
    # come from a real keyframe index. When the source is in a container
    # we don't index (anything but .mkv right now), drop the codec from
    # the client profile so Decision falls through to `:transcode`
    # instead of shipping a playlist that disagrees with ffmpeg's
    # `-c copy` output (which would surface as Safari MEDIA_ERR_DECODE).
    # Mirrors upstream Jellyfin's `IsRemuxingVideo` gating in
    # DynamicHlsPlaylistGenerator.cs:38 — they only build a keyframe-
    # based playlist when a working extractor is available.
    downgrade_remux_when_no_keyframes!(client_profile, media_source, file_path)

    # Decide the delivery method BEFORE encoding tokens — the token bakes
    # in `video_codec` / `audio_codec`, which determines whether the
    # engine re-encodes (libx264/aac defaults) or stream-copies. For a
    # :direct_stream decision (codecs already match the client, only the
    # container is wrong), we want ffmpeg `-c copy -f hls` so Safari
    # plays HEVC+AC3 natively without a full re-encode.
    pre_decision = Jellyfin::Playback::Decision.call(
      media_source: media_source,
      profile: client_profile,
      requested: { audio_track: audio_stream_index,
                   subtitle_track: subtitle_stream_index,
                   max_bitrate: client_profile.max_video_bitrate }
    )

    transcode_token_params = {
      path: file_path,
      audio_track: audio_stream_index,
      subtitle_track: is_bitmap ? subtitle_stream_index : nil,
      # Tell the engine to BURN the bitmap subtitle into the video stream.
      # Without this, `EncodingJobInfo#subtitle_method` defaults to `:soft`
      # and `burn_subtitles?` returns false → the overlay filter is never
      # inserted into the filter chain, so the bitmap track is silently
      # ignored (no error, no subs, no warning). Setting it to `:encode`
      # is what flips `Filters::SubtitleBurn.build` on in
      # `encoding_helper.rb:297` and the engine renders the PGS planes
      # onto the video frames before re-encoding. Only sent when we've
      # actually picked a bitmap stream — soft subs stay soft so text-sub
      # paths don't get yanked onto the burn-in path by mistake.
      subtitle_mode: is_bitmap ? "encode" : nil,
      # NOTE: start_time is intentionally NOT baked into the token. The player
      # JS does `video.currentTime = startTime` after loading the master
      # playlist (`seekOnPlaybackStart` in `player/src/media-helper.ts`), and
      # hls.js then requests the segment that covers that timestamp. Mirrors
      # upstream Jellyfin's `DynamicHlsController.GetDynamicSegment`
      # (Jellyfin.Api/Controllers/DynamicHlsController.cs:1430-1432) which
      # explicitly rejects `StartTimeTicks` on segment requests — the seek
      # is per-segment-request, not per-session. The far-ahead segment
      # request triggers `TranscodeManager#request_segment` →
      # `restart_at_segment` which spawns ffmpeg with the correct
      # `-ss N*segment_length -start_number N`.
      #
      # Baking `start_time_ticks` here caused a double-seek bug for any
      # `startTime > segment_length`: the engine seeked ffmpeg by `-ss
      # startTime` AND the player seeked the playlist by `currentTime =
      # startTime`. Playlist's "segment 4" then meant `source 24-30s`
      # to the player but `source 48-54s` to ffmpeg. Resume on Aladdin
      # at 24s hung Safari on a 4.ts that ffmpeg was naming 0.ts.
      max_bitrate: client_profile.max_video_bitrate,
      # Master-playlist rendition gating. Mirrors upstream's
      # SubtitleDeliveryMethod enum: only when the client's DeviceProfile
      # explicitly declares `Method=Hls` for a subtitle format does the
      # engine emit `EXT-X-MEDIA:TYPE=SUBTITLES`. For everything else
      # (External / Embed / Encode) the master stays bare and the
      # client fetches subs out-of-band — Caramba's adapters always
      # declare `Method=External` for vtt, so this resolves to nil
      # ⇒ engine treats as External ⇒ no subtitle MEDIA in master.
      subtitle_delivery: hls_subtitle_delivery?(device_profile_raw) ? "hls" : nil,
      # HLS trickplay is opt-in. Caramba doesn't render HLS trickplay
      # today, so this stays false. When it does, set `trickplay: true`
      # in the DeviceProfile and the engine will emit the
      # EXT-X-IMAGE-STREAM-INF entries.
      trickplay: hls_trickplay?(device_profile_raw) || nil
    }.compact
    if pre_decision.direct_stream?
      # `video_codec=copy` and `subtitle_mode=encode` are MUTUALLY EXCLUSIVE.
      # Stream-copy skips the filter chain (ffmpeg never decodes frames),
      # so the PGS overlay filter can't run — the burn-in silently no-ops
      # and the segments either come out without subs OR ffmpeg hangs on
      # init because `-map [vout]` references a label nothing produced.
      # When we've committed to burning a bitmap sub, force re-encode of
      # the video; audio can still copy. (`audio_codec=copy` stays a safe
      # win because the audio path doesn't run through any video filter.)
      transcode_token_params[:video_codec] = "copy" unless is_bitmap
      transcode_token_params[:audio_codec] = "copy"
    end

    # Pick the segment container from the client's TranscodingProfiles.
    # Mirrors upstream Jellyfin's `StreamBuilder.GetVideoTranscodeProfile`
    # selection: walk TranscodingProfiles in order, take the first whose
    # `VideoCodec` covers the codec we'll emit. jellyfin-web's
    # `browserDeviceProfile.js:910` pushes the fMP4 profile FIRST and the
    # MPEG-TS profile second, so HEVC sources (and every h264 transcode
    # that fMP4 also accepts) end up as fMP4 segments — that's exactly
    # what Safari fetches when playing the same content via Jellyfin's
    # native client. Without this branch the engine fell back to its
    # `ts` default for full transcodes, and Safari hung on the `*.ts`
    # output for 4K HDR HEVC → h264 jobs.
    target_video_codec = transcode_token_params[:video_codec] == "copy" ?
      info.dig(:video, :codec).to_s.downcase : "h264"
    selected_container = pick_segment_container(device_profile_raw, target_video_codec)
    transcode_token_params[:segment_container] = selected_container if selected_container

    direct_token    = Jellyfin::Transcoding::Token.encode(path: file_path)
    transcode_token = Jellyfin::Transcoding::Token.encode(transcode_token_params)

    subtitle_url = subtitle_delivery_url(
      subtitle_streams: info[:subtitleStreams],
      subtitle_stream_index: subtitle_stream_index,
      is_bitmap: is_bitmap,
      token: direct_token
    )

    # PlaybackInfo.for composes URLs as `"#{base_url}/stream/..."` and
    # `"#{base_url}/transcode/..."` — relative to the engine's mount point,
    # not Rails root. Engine is mounted at /_jellyfin, so we pass that prefix
    # in the base_url. Without it the client gets /transcode/... and 404s.
    decision = Jellyfin::Playback::PlaybackInfo.for(
      media_source: media_source,
      profile: client_profile,
      audio_track: audio_stream_index,
      subtitle_track: subtitle_stream_index,
      max_bitrate: client_profile.max_video_bitrate,
      base_url: "#{api_base_url}/_jellyfin",
      token_for_direct: direct_token,
      token_for_transcode: transcode_token
    )

    strategy = derive_strategy(decision, info, audio_stream_index, client_profile, is_bitmap)
    is_direct_play = decision.method == :direct_play
    stream_url = is_direct_play ? decision.direct_play_url : decision.transcoding_url
    job_id = Digest::SHA1.hexdigest(transcode_token)[0, 16]

    # Cancel any orphan ffmpeg process from a previous /start call in the
    # same Rails session that didn't get a corresponding /stop. Audio +
    # subtitle switches re-issue /start with new tokens, so the previous
    # job's id no longer matches the new token's hash and the client's
    # stopPlayback (which fires at player close) would only reach the
    # newest job — orphans accumulated on every switch and pegged the CPU.
    previous_job_id = session[:playback_session_id]
    if previous_job_id.present? && previous_job_id != job_id
      Jellyfin::Transcoding::TranscodeManager.instance.cancel!(previous_job_id)
    end
    session[:playback_session_id] = job_id

    render json: {
      hlsUrl: stream_url,
      streamUrl: stream_url,
      sessionId: job_id,
      duration: info[:duration],
      startTime: start_time,
      seekBase: 0,
      subtitleUrl: subtitle_url,
      video: info[:video],
      bitrate: info[:bitrate],
      audioStreams: info[:audioStreams],
      subtitleStreams: info[:subtitleStreams],
      activeAudioIndex: audio_stream_index,
      activeSubtitleIndex: subtitle_stream_index,
      isBitmapSubtitle: is_bitmap,
      strategy: strategy
    }
  rescue => e
    Rails.logger.error "[Playback] start error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # POST /api/playback/stop
  def stop_playback
    session_id = params[:session]
    if session_id.present?
      mgr = Jellyfin::Transcoding::TranscodeManager.instance
      job_present = !!mgr.send(:find, session_id)
      Rails.logger.info "[Playback] stop session=#{session_id} found_job=#{job_present}"
      mgr.cancel!(session_id)
    else
      Rails.logger.info "[Playback] stop received with no session param"
    end

    time = params[:time].to_i
    duration = params[:duration].to_i

    if duration > 0
      if params[:episode_id].present?
        ep = Episode.find_by(id: params[:episode_id])
        if ep
          ep.update_progress!(time, duration)
          ep.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
        end
      end

      if params[:movie_id].present?
        movie = Movie.find_by(id: params[:movie_id])
        if movie
          movie.update_progress!(time, duration)
          movie.mark_watched! if time.to_f / duration >= Watchable::WATCHED_THRESHOLD
        end
      end
    end

    render json: { ok: true }
  end

  private

  def find_record_for(file_path)
    Episode.find_by(file_path: file_path) || Movie.find_by(file_path: file_path)
  end

  def find_preference
    if params[:type] == "episode" && params[:show_id].present?
      PlaybackPreference.find_by(show_id: params[:show_id])
    elsif params[:type] == "movie" && params[:movie_id].present?
      PlaybackPreference.find_by(movie_id: params[:movie_id])
    end
  end

  def preference_attrs
    {
      audio_language: params[:audioLanguage],
      audio_codec: params[:audioCodec],
      audio_channels: params[:audioChannels],
      subtitle_language: params[:subtitleLanguage],
      subtitle_off: params[:subtitleOff] ? 1 : 0,
      subtitle_size: params[:subtitleSize] || "medium",
      subtitle_style: params[:subtitleStyle] || "classic"
    }
  end

  # Audio track selection. Precedence (most specific first):
  #   1. Saved (language, codec, channels) — disambiguates AAC stereo vs 5.1.
  #   2. Saved (language, codec) — handles TrueHD eng + AC3 eng pairs.
  #   3. Saved language — prefer a profile-decodable codec to stay direct.
  #   4. English with same preference.
  #   5. First available track, biased to cheap-to-transcode codecs.
  def select_audio_track(audio_streams, prefs, device_profile)
    return nil if audio_streams.blank?

    saved_lang     = prefs && prefs[:audioLanguage].presence
    saved_codec    = prefs && prefs[:audioCodec].presence
    saved_channels = prefs && prefs[:audioChannels].presence
    desired_lang = saved_lang || "eng"

    if saved_lang && saved_codec && saved_channels
      exact = audio_streams.find { |s|
        matches_language?(s[:language], saved_lang) &&
          s[:codec] == saved_codec &&
          s[:channels].to_i == saved_channels.to_i
      }
      return exact[:index] if exact
    end

    if saved_lang && saved_codec
      exact = audio_streams.find { |s|
        matches_language?(s[:language], saved_lang) && s[:codec] == saved_codec
      }
      return exact[:index] if exact
    end

    in_lang = audio_streams.select { |s| matches_language?(s[:language], desired_lang) }
    in_lang = audio_streams if in_lang.empty?

    supported = supported_audio_codecs(device_profile)
    playable = in_lang.find { |s| supported.include?(s[:codec].to_s.downcase) }
    return playable[:index] if playable

    cheap = in_lang.find { |s| CHEAP_AUDIO_CODECS.include?(s[:codec]) }
    (cheap || in_lang.first)[:index]
  end

  CHEAP_AUDIO_CODECS = %w[aac ac3 eac3 mp3 flac opus vorbis].freeze

  def matches_language?(stream_language, requested)
    return true if stream_language.to_s == requested.to_s
    requested == "eng" && stream_language.to_s == "en" ||
      requested == "en" && stream_language.to_s == "eng"
  end

  # Pick a subtitle track and decide whether the server must burn it in.
  # Returns [stream_index, burn_required]. burn=true only for bitmap subs the
  # client can't render (PGS/DVB/DVD with no Embed entry in SubtitleProfiles).
  def select_subtitle_track(subtitle_streams, prefs, device_profile)
    return [ nil, false ] if subtitle_streams.blank?
    return [ nil, false ] if prefs && prefs[:subtitleOff]

    picked = pick_subtitle_track(subtitle_streams, prefs)
    return [ nil, false ] unless picked

    method = subtitle_method_for(device_profile, picked[:codec])
    return [ picked[:index], false ] if method
    return [ picked[:index], false ] if picked[:isText]
    # Auto-pick landed on a bitmap (PGS/DVB/DVD) track that the client can't
    # render natively. Burning it in requires full SW transcode (the HW
    # overlay graph in jellyfin-rails isn't ported yet, so resolve_hwaccel
    # refuses the HW backend for graphical burn-in). Rather than silently
    # downgrade the entire title to CPU encoding just because the user has
    # a saved language preference, drop the subtitle. The user can still
    # explicitly pick the PGS track from the player UI when they actually
    # want subs burned in for that title.
    [ nil, false ]
  end

  def pick_subtitle_track(streams, prefs)
    if prefs && prefs[:subtitleLanguage].present?
      lang = prefs[:subtitleLanguage]
      text_match = streams.find { |s| s[:isText] && s[:language] == lang }
      return text_match if text_match
      bitmap_match = streams.find { |s| !s[:isText] && s[:language] == lang }
      return bitmap_match if bitmap_match
    end
    streams.find { |s| s[:isText] }
  end

  def supported_audio_codecs(device_profile)
    Set.new(Array(device_profile&.dig("DirectPlayProfiles")).flat_map { |entry|
      entry["AudioCodec"].to_s.split(/\s*,\s*/).map(&:downcase)
    })
  end

  # Walks the client's TranscodingProfiles (in declaration order) and
  # returns the Container of the first entry whose VideoCodec list covers
  # `target_video_codec`. Used to pick `segment_container` for the HLS
  # output. Mirrors upstream Jellyfin's behaviour where jellyfin-web's
  # `browserDeviceProfile.js:910` deliberately places the fMP4 profile
  # before the MPEG-TS profile so HEVC sources stream-copy into fMP4
  # and h264 transcodes also land in fMP4 segments (the second `ts`
  # profile only wins when the first doesn't cover the codec — e.g.
  # legacy devices that omit the fMP4 profile entirely).
  def pick_segment_container(device_profile, target_video_codec)
    return nil if device_profile.nil?
    target = target_video_codec.to_s.downcase
    Array(device_profile["TranscodingProfiles"]).each do |entry|
      next unless entry["Type"].to_s.casecmp?("video")
      next unless entry["Protocol"].to_s.casecmp?("hls")
      codecs = entry["VideoCodec"].to_s.split(/\s*,\s*/).map(&:downcase)
      next unless codecs.any? { |c| segment_codec_match?(c, target) }
      container = entry["Container"].to_s.downcase
      return container if %w[mp4 ts].include?(container)
    end
    nil
  end

  # Loose codec equality for matching client-declared codecs against the
  # codec ffmpeg will emit. Mirrors `Decision#codec_alias?` so the same
  # h264/avc and hevc/h265 synonyms resolve identically here and in the
  # direct-play decision tree.
  def segment_codec_match?(declared, target)
    return true if declared == target
    eq = [ %w[h264 avc], %w[hevc h265 h.265], %w[av1 av01] ]
    eq.any? { |group| group.include?(declared) && group.include?(target) }
  end

  # True when the client's DeviceProfile lists at least one SubtitleProfile
  # whose Method is "Hls". Mirrors upstream Jellyfin's choice of
  # SubtitleDeliveryMethod.Hls when DLNA matching picks an Hls profile.
  # Caramba's adapters declare `{Format:'vtt', Method:'External'}` so this
  # returns false — keeping the master playlist free of subtitle MEDIA
  # references and letting the UI fetch subs through its own endpoint.
  def hls_subtitle_delivery?(device_profile)
    return false if device_profile.nil?
    Array(device_profile["SubtitleProfiles"]).any? do |entry|
      entry["Method"].to_s.casecmp?("hls")
    end
  end

  # True when the client opted into HLS trickplay (EXT-X-IMAGE-STREAM-INF
  # entries on the master). Not part of the standard DLNA schema; checked
  # as a top-level `Trickplay` flag on the DeviceProfile.
  def hls_trickplay?(device_profile)
    return false if device_profile.nil?
    value = device_profile["Trickplay"] || device_profile["EnableTrickplay"]
    return false if value.nil?
    %w[1 true yes on].include?(value.to_s.downcase) || value == true
  end

  # Walk SubtitleProfiles for an entry whose Format matches the source codec.
  # Returns the Method string ("External" or "Embed"), or nil if no entry
  # covers it (caller falls back to burn-in for bitmap subs).
  def subtitle_method_for(device_profile, codec)
    return nil if device_profile.nil?
    normalized = subtitle_codec_alias(codec)
    Array(device_profile["SubtitleProfiles"]).each do |entry|
      formats = entry["Format"].to_s.downcase.split(/\s*,\s*/)
      return entry["Method"] if formats.include?(normalized)
    end
    nil
  end

  def subtitle_codec_alias(codec)
    case codec.to_s.downcase
    when "subrip" then "srt"
    when "ass" then "ssa"
    when "hdmv_pgs_subtitle" then "pgssub"
    else codec.to_s.downcase
    end
  end

  # Source codecs we'd stream-copy through the keyframe-indexed path.
  # MKV Cues give us a real keyframe list per source; without that the
  # variant playlist would lie about segment durations. Aliases mirror
  # the equivalence groups in `Jellyfin::Playback::Decision#codec_alias?`
  # so we don't leave a synonym in the profile after the downgrade.
  REMUX_CODECS_REQUIRING_KEYFRAMES = %w[hevc h265 h.265 av1 av01].freeze

  def downgrade_remux_when_no_keyframes!(profile, media_source, file_path)
    codec = media_source.default_video_stream&.codec.to_s.downcase
    return unless REMUX_CODECS_REQUIRING_KEYFRAMES.include?(codec)
    return if Jellyfin::Keyframes::Extractor.for(file_path)
    profile.video_codecs = profile.video_codecs.reject do |c|
      REMUX_CODECS_REQUIRING_KEYFRAMES.include?(c.to_s.downcase)
    end
  end

  # Maps engine decision + Caramba's burn flag to Caramba's four legacy
  # strategy labels. Strategy is informational on the client (dev-mode pill);
  # the actual delivery is determined by which URL was returned.
  def derive_strategy(decision, info, audio_stream_index, client_profile, is_bitmap)
    return "direct_play" if decision.method == :direct_play
    return "direct_stream" if decision.method == :direct_stream
    return "full_transcode" if is_bitmap

    audio_codec = info[:audioStreams].to_a.find { |s| s[:index] == audio_stream_index }&.dig(:codec)
    video_codec = info.dig(:video, :codec)
    video_ok = client_profile.video_codecs.map(&:downcase).include?(video_codec.to_s.downcase)
    audio_ok = audio_codec && client_profile.audio_codecs.map(&:downcase).include?(audio_codec.to_s.downcase)

    if video_ok && !audio_ok
      "audio_transcode"
    else
      "full_transcode"
    end
  end

  def parse_device_profile(raw)
    return nil if raw.nil?
    parsed = if raw.respond_to?(:to_unsafe_h)
               raw.to_unsafe_h
    elsif raw.is_a?(Hash)
               raw
    else
               JSON.parse(raw.to_s)
    end
    parsed.deep_stringify_keys
  rescue JSON::ParserError
    nil
  end

  # External subtitle URL — only for text subs that the client renders itself
  # (vtt/srt/ass/ssa/mov_text/etc). Bitmap subs (PGS/DVB/DVDsub) take the
  # `is_bitmap = true` branch and get burned into the transcode upstream,
  # so the client never fetches them. Mirrors upstream Jellyfin's
  # SubtitleDeliveryMethod=External path (StreamInfo.cs:1254): a token-based
  # URL that the engine resolves with ffmpeg `-map 0:s:<relative_index>` —
  # the URL carries the SUBTITLE-RELATIVE index, not the absolute stream
  # index (see Jellyfin::SubtitlesController#extract_to).
  #
  # NOTE: WebVTT cue timestamps stay at ABSOLUTE source time because the
  # engine's VOD playlist is built with `seek_seconds: 0` regardless of the
  # actual playback resume point (transcoding_controller.rb:321) — every
  # /start call ships the same full 0..total playlist and the transcoder
  # restarts ffmpeg per requested segment. So hls.js drives
  # `video.currentTime` in absolute source-time, and unshifted cues align.
  # Routing through the engine's `with_ticks` endpoint with the default
  # `preserve_original_timestamps = false` would rebase cues to start at 0
  # and push them off by exactly the resume offset.
  def subtitle_delivery_url(subtitle_streams:, subtitle_stream_index:, is_bitmap:, token:)
    return nil if subtitle_stream_index.nil? || is_bitmap
    relative_idx = Array(subtitle_streams).index { |s| s[:index] == subtitle_stream_index }
    return nil if relative_idx.nil?
    "#{api_base_url}/_jellyfin/subtitles/#{token}/#{relative_idx}.vtt"
  end

  def api_base_url
    host = request.headers["X-Forwarded-Host"] || request.host_with_port
    protocol = request.headers["X-Forwarded-Proto"] || request.protocol.sub("://", "")
    @api_base_url ||= "#{protocol}://#{host}"
  end
end
