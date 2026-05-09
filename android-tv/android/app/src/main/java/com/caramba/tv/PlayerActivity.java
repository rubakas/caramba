package com.caramba.tv;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackGroup;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.common.Tracks;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.hls.HlsMediaSource;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.ProgressiveMediaSource;
import androidx.media3.ui.PlayerView;

import com.getcapacitor.JSObject;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;


/**
 * Full-screen ExoPlayer surface launched by {@link CarambaPlayerPlugin}.
 *
 * Layout mirrors the WebView TV player (`isAndroidTV` branch in
 * VideoPlayer.jsx): minimal top-title + bottom-seekbar overlay; UP shows
 * the audio panel; DOWN shows the subtitle panel; BACK closes or returns.
 *
 * @noinspection UnstableApiUsage
 */
@UnstableApi
public class PlayerActivity extends Activity {
    private static final String TAG = "CarambaPlayerActivity";
    private static final long PROGRESS_INTERVAL_MS = 10_000L;
    private static final long SEEK_STEP_MS = 10_000L;
    private static final long UI_TICK_MS = 250L;
    private static final long CONTROLS_HIDE_DELAY_MS = 4_000L;
    /** Hold off the server-side seek round-trip until the user has stopped
     *  pressing LEFT/RIGHT for this long. Lets them stack multiple steps
     *  without each one restarting ffmpeg. */
    private static final long SEEK_DEBOUNCE_MS = 700L;

    /** UI mode — same state machine as the WebView TV player. */
    private enum TvMode { SEEK, AUDIO, SUBTITLES }

    // ── ExoPlayer ─────────────────────────────────────────────────────
    private ExoPlayer player;
    private PlayerView playerView;

    // ── Top: title block ──────────────────────────────────────────────
    private LinearLayout topPanel;
    private TextView titleText;
    private TextView subtitleText;

    // ── Center: pause / spinner ───────────────────────────────────────
    private View centerPanel;
    private View centerSpinner;
    private View centerPause;

    // ── Bottom: seek bar + hints ──────────────────────────────────────
    private LinearLayout bottomPanel;
    private TextView elapsedText;
    private TextView remainingText;
    private ProgressBar seekBar;
    private TextView hintText;

    // ── Audio panel ───────────────────────────────────────────────────
    private LinearLayout audioPanel;
    private LinearLayout audioList;

    // ── Subtitle panel ────────────────────────────────────────────────
    private LinearLayout subtitlePanel;
    private LinearLayout subtitleList;

    // ── Debug overlay ─────────────────────────────────────────────────
    private TextView debugOverlay;
    // On by default in debug builds, off in release. Toggle with INFO/YELLOW.
    private boolean debugOverlayShown = BuildConfig.DEBUG;

    // ── Timers ────────────────────────────────────────────────────────
    private Handler progressHandler;
    private final Runnable progressTick = this::emitProgress;
    private Handler uiHandler;
    private final Runnable uiTick = this::onUiTick;
    private long lastInteractionMs;

    // ── Session state ─────────────────────────────────────────────────
    private String sessionId = "";
    private String strategy = "";
    /** Where in the source the player's position 0 corresponds to.
     *  - HLS (transcoded): the ffmpeg `-ss` offset; player position is
     *    relative to ffmpeg's output, so add this to get source seconds.
     *  - direct_play with a clipping config: the clip start in the source;
     *    ExoPlayer reports getCurrentPosition() relative to the clip, so
     *    again add this to get true source seconds.
     *  - direct_play without a clip and no resume: 0. */
    private double sourceOffset = 0d;
    private boolean ended = false;
    private boolean dismissedFromJs = false;
    /** Direct-to-server reporting, bypassing the JS bridge. The Capacitor
     *  WebView is in a paused MainActivity while PlayerActivity is foreground,
     *  which makes notifyListeners → JS → fetch chains unreliable for long
     *  playback sessions — events queue up or get dropped and progress never
     *  lands on the Rails server. Posting from here is ~3 lines and 100%
     *  reliable for the long-lived session. The JS-side listener still runs
     *  too; duplicate updates are idempotent (last-writer-wins on a single
     *  numeric column). */
    private String apiBase = "";
    private long episodeIdForServer = 0;
    private long movieIdForServer = 0;
    private long watchHistoryIdForServer = 0;
    private final ExecutorService httpExecutor = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "CarambaPlayer-http");
        t.setDaemon(true);
        return t;
    });
    /** Set the first time ExoPlayer hits STATE_READY for this session — used
     *  to emit a one-shot `ready` event back to JS so the React UI can
     *  dismiss its launching overlay. Reset on every loadFromPayload so
     *  audio-switch / seek round-trips re-fire it. */
    private boolean readyEmitted = false;
    private TvMode tvMode = TvMode.SEEK;
    private double payloadDuration = 0d;
    private JSObject lastPayload;
    // Track URLs across loadFromPayload calls so we can tell apart a
    // subtitle-only swap (no position reset) from a full reload (server
    // restarted ffmpeg for seek/audio-switch — must reset).
    private String currentHlsUrl;
    private String currentStreamUrl;
    private String currentSubtitleUrl;

    /** Pending seek target in absolute seconds. -1 means no pending seek. */
    private double pendingSeekTarget = -1d;
    private final Runnable commitSeekRunnable = this::commitPendingSeek;

    /** Latest Tracks snapshot from ExoPlayer; used to populate the audio /
     *  subtitle pickers in direct_play mode where there's no server-side
     *  ffmpeg session to round-trip through. */
    private Tracks lastTracks;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setContentView(R.layout.activity_player);

        // Bind views
        playerView       = findViewById(R.id.player_view);
        topPanel         = findViewById(R.id.top_panel);
        titleText        = findViewById(R.id.title_text);
        subtitleText     = findViewById(R.id.subtitle_text);
        centerPanel      = findViewById(R.id.center_panel);
        centerSpinner    = findViewById(R.id.center_spinner);
        centerPause      = findViewById(R.id.center_pause);
        bottomPanel      = findViewById(R.id.bottom_panel);
        elapsedText      = findViewById(R.id.elapsed_text);
        remainingText    = findViewById(R.id.remaining_text);
        seekBar          = findViewById(R.id.seek_bar);
        hintText         = findViewById(R.id.hint_text);
        audioPanel       = findViewById(R.id.audio_panel);
        audioList        = findViewById(R.id.audio_list);
        subtitlePanel    = findViewById(R.id.subtitle_panel);
        subtitleList     = findViewById(R.id.subtitle_list);
        debugOverlay     = findViewById(R.id.debug_overlay);

        progressHandler = new Handler(Looper.getMainLooper());
        uiHandler = new Handler(Looper.getMainLooper());

        CarambaPlayerSession.current = this;

        JSObject payload = CarambaPlayerSession.pendingPayload;
        if (payload == null) {
            Log.w(TAG, "No pending payload; finishing");
            finish();
            return;
        }

        buildPlayer();
        loadFromPayload(payload, /* isUpdate */ false);
        // For the stub payload (no URL yet), show the loading spinner up
        // front instead of waiting for the player to enter STATE_BUFFERING
        // — there's no media set yet, so that state never arrives.
        if (payload.optBoolean("pending", false)) {
            showLoadingSpinner();
        }
        setTvMode(TvMode.SEEK);
        kickInteraction();
        uiHandler.post(uiTick);
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        JSObject payload = CarambaPlayerSession.pendingPayload;
        if (payload != null) {
            loadFromPayload(payload, /* isUpdate */ true);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (player != null) player.play();
        if (uiHandler != null) {
            uiHandler.removeCallbacks(uiTick);
            uiHandler.post(uiTick);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (player != null) player.pause();
        if (uiHandler != null) uiHandler.removeCallbacks(uiTick);
    }

    @Override
    protected void onDestroy() {
        stopProgressTimer();
        if (uiHandler != null) {
            uiHandler.removeCallbacks(uiTick);
            uiHandler.removeCallbacks(commitSeekRunnable);
        }

        if (player != null) {
            // Last chance to record where the user stopped — needed for the
            // resume_time on next launch. The JS-side closePlayer also POSTs
            // /api/playback/stop, but that round-trip can lose the race
            // against the WebView re-paint when MainActivity comes back to
            // the foreground; this direct call always lands.
            postProgressDirect();
            if (!dismissedFromJs) {
                emit("dismissed", buildLifecycleEvent("back"));
            }
            player.release();
            player = null;
        }
        if (CarambaPlayerSession.current == this) {
            CarambaPlayerSession.current = null;
        }
        httpExecutor.shutdown();
        super.onDestroy();
    }

    // ── key dispatch ──────────────────────────────────────────────────

    /**
     * Two-mode key handling that mirrors the WebView TV player:
     *
     *   SEEK mode:
     *     LEFT/RIGHT → seek 10s
     *     CENTER     → play/pause
     *     UP         → AUDIO mode
     *     DOWN       → SUBTITLES mode
     *     BACK       → close
     *   AUDIO / SUBTITLES mode:
     *     UP/DOWN    → list focus traversal (handled by Android focus engine)
     *     CENTER     → activate focused item (handled by item)
     *     BACK       → back to SEEK
     */
    @Override
    public boolean dispatchKeyEvent(@NonNull KeyEvent event) {
        if (event.getAction() != KeyEvent.ACTION_DOWN) {
            return super.dispatchKeyEvent(event);
        }
        kickInteraction();
        int keyCode = event.getKeyCode();

        if (keyCode == KeyEvent.KEYCODE_PROG_YELLOW || keyCode == KeyEvent.KEYCODE_INFO) {
            toggleDebugOverlay();
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (tvMode != TvMode.SEEK) {
                setTvMode(TvMode.SEEK);
                return true;
            }
            return super.dispatchKeyEvent(event);
        }

        if (tvMode == TvMode.SEEK) {
            if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT) {
                handleSeekStep(-SEEK_STEP_MS);
                return true;
            }
            if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) {
                handleSeekStep(SEEK_STEP_MS);
                return true;
            }
            if (keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
                    || keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                    || keyCode == KeyEvent.KEYCODE_ENTER) {
                togglePlayPause();
                return true;
            }
            if (keyCode == KeyEvent.KEYCODE_DPAD_UP || keyCode == KeyEvent.KEYCODE_MENU) {
                setTvMode(TvMode.AUDIO);
                return true;
            }
            if (keyCode == KeyEvent.KEYCODE_DPAD_DOWN) {
                setTvMode(TvMode.SUBTITLES);
                return true;
            }
            return super.dispatchKeyEvent(event);
        }

        // AUDIO / SUBTITLES — let the focused list item handle UP/DOWN/ENTER.
        return super.dispatchKeyEvent(event);
    }

    private void togglePlayPause() {
        if (player == null) return;
        if (player.isPlaying()) player.pause(); else player.play();
    }

    // ── plugin-callable helpers ───────────────────────────────────────

    public void applyUpdate(JSObject payload) { loadFromPayload(payload, true); }
    public void pausePlayback()  { if (player != null) player.pause(); }
    public void resumePlayback() { if (player != null) player.play(); }
    public void seekToSeconds(double s) { if (player != null) player.seekTo((long) (s * 1000d)); }
    public void finishFromJs() { dismissedFromJs = true; finish(); }

    public double getCurrentSeconds() {
        if (player == null) return 0d;
        long pos = player.getCurrentPosition();
        return sourceOffset + (pos > 0 ? pos / 1000d : 0d);
    }

    public double getDurationSeconds() {
        // The payload's `duration` is the full source duration as ffprobed
        // by the server. ExoPlayer's getDuration() on HLS event playlists
        // only reports the range it currently knows about, so the seek bar
        // would otherwise creep up as new segments arrive.
        if (payloadDuration > 0d) return payloadDuration;
        if (player == null) return 0d;
        long dur = player.getDuration();
        return dur > 0 ? dur / 1000d : 0d;
    }

    public boolean isPaused() { return player == null || !player.isPlaying(); }
    public boolean isEnded()  { return ended; }

    // ── ExoPlayer setup ───────────────────────────────────────────────

    private void buildPlayer() {
        DefaultRenderersFactory renderers = new DefaultRenderersFactory(this)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF);

        player = new ExoPlayer.Builder(this, renderers).build();
        playerView.setPlayer(player);

        // Default track selector matches text tracks against the user's
        // preferred languages — when our SubtitleConfiguration's language
        // doesn't line up (or isn't set), no text track gets selected at
        // all. selectUndeterminedTextLanguage=true plus an explicit
        // PreferredTextLanguage of "und" makes the renderer accept any
        // text track marked DEFAULT regardless of language.
        player.setTrackSelectionParameters(
                player.getTrackSelectionParameters().buildUpon()
                        .setSelectUndeterminedTextLanguage(true)
                        .build()
        );

        player.addListener(new Player.Listener() {
            @Override
            public void onPlaybackStateChanged(int state) {
                updateCenterPanel();
                if (state == Player.STATE_READY && !readyEmitted) {
                    readyEmitted = true;
                    JSObject ev = new JSObject();
                    ev.put("sessionId", sessionId);
                    emit("ready", ev);
                }
                if (state == Player.STATE_ENDED && !ended) {
                    handleEndOfStream();
                }
            }
            @Override
            public void onIsPlayingChanged(boolean isPlaying) {
                updateCenterPanel();
                if (isPlaying) startProgressTimer(); else stopProgressTimer();
            }
            @Override
            public void onPlayerError(@NonNull PlaybackException error) {
                Log.e(TAG, "ExoPlayer error", error);
                JSObject ev = new JSObject();
                ev.put("sessionId", sessionId);
                ev.put("code", error.errorCode);
                ev.put("message", error.getMessage() != null ? error.getMessage() : error.getErrorCodeName());
                ev.put("recoverable", false);
                emit("error", ev);
            }
            @Override
            public void onTracksChanged(@NonNull Tracks tracks) {
                lastTracks = tracks;
                int textGroups = 0, audioGroups = 0, videoGroups = 0;
                for (Tracks.Group g : tracks.getGroups()) {
                    if (g.getType() == C.TRACK_TYPE_TEXT) textGroups++;
                    else if (g.getType() == C.TRACK_TYPE_AUDIO) audioGroups++;
                    else if (g.getType() == C.TRACK_TYPE_VIDEO) videoGroups++;
                }
                Log.i(TAG, "onTracksChanged: groups text=" + textGroups
                        + " audio=" + audioGroups + " video=" + videoGroups);

                if (isDirectPlayStrategy()) {
                    // direct_play: tracks come from the source container directly;
                    // we don't burn-in or remux. Repopulate the pickers using
                    // ExoPlayer's actual track list so the user can switch
                    // audio/subtitle locally without a server round-trip.
                    populateAudioList();
                    populateSubtitleList();
                } else {
                    forceSelectTextTrack(tracks);
                }
            }
        });
    }

    private void forceSelectTextTrack(Tracks tracks) {
        if (player == null || tracks == null) return;
        boolean wantText = currentSubtitleUrl != null
                && !currentSubtitleUrl.isEmpty()
                && !lastPayloadIsBitmapSubtitle();

        TrackSelectionParameters params = player.getTrackSelectionParameters();
        TrackSelectionParameters.Builder b = params.buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_TEXT);

        if (!wantText) {
            b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true);
            player.setTrackSelectionParameters(b.build());
            return;
        }

        // Find the first text group and override-select its first track.
        boolean overridden = false;
        for (Tracks.Group group : tracks.getGroups()) {
            if (group.getType() == C.TRACK_TYPE_TEXT) {
                TrackGroup tg = group.getMediaTrackGroup();
                if (tg.length > 0) {
                    b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false);
                    b.setOverrideForType(new TrackSelectionOverride(tg, 0));
                    Log.i(TAG, "forceSelectTextTrack: overrode to text group, length=" + tg.length);
                    overridden = true;
                    break;
                }
            }
        }
        if (!overridden) {
            // Text wanted but no group available yet — re-enable text and
            // wait. onTracksChanged will fire again when the renderer
            // discovers the WebVTT track.
            b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false);
        }
        player.setTrackSelectionParameters(b.build());
    }

    private boolean lastPayloadIsBitmapSubtitle() {
        return lastPayload != null && lastPayload.optBoolean("isBitmapSubtitle", false);
    }

    private void loadFromPayload(JSObject payload, boolean isUpdate) {
        lastPayload = payload;
        sessionId = payload.optString("sessionId", sessionId);
        // The stub present() — fired the moment the user clicks Play, before
        // /api/playback/start returns — carries pending:true and no media
        // URL. The Activity opens, shows its loading spinner, and waits for
        // the real updateStream() to arrive with the actual session data.
        // Without this guard we'd treat the stub as a real payload and try
        // to build a MediaSource from null.
        if (payload.optBoolean("pending", false)) {
            strategy = "";
            ended = false;
            readyEmitted = false;
            showLoadingSpinner();
            return;
        }
        strategy = payload.optString("strategy", "");
        boolean isDirectPlayStrat = "direct_play".equals(strategy);
        // sourceOffset is set below — for direct_play we override it with
        // the clip start (since ExoPlayer reports clip-relative position),
        // for HLS we use the server's seekBase (ffmpeg -ss offset).
        sourceOffset = isDirectPlayStrat
                ? payload.optDouble("startTime", 0d)
                : payload.optDouble("seekBase", 0d);
        // payload.duration is the full source duration from the server's
        // ffprobe (start payload). Persist it across track switches —
        // updateStream payloads don't always carry it.
        double dur = payload.optDouble("duration", 0d);
        if (dur > 0d) payloadDuration = dur;
        ended = false;
        readyEmitted = false;

        // Persist server-reporting context. updateStream payloads don't
        // always carry these (track switches preserve the session), so only
        // overwrite when the new payload provides a value.
        String newApiBase = payload.optString("apiBase", "");
        if (!newApiBase.isEmpty()) apiBase = newApiBase;
        long newEp = payload.optLong("episodeId", 0L);
        if (newEp > 0L) episodeIdForServer = newEp;
        long newMv = payload.optLong("movieId", 0L);
        if (newMv > 0L) movieIdForServer = newMv;
        long newWh = payload.optLong("watchHistoryId", 0L);
        if (newWh > 0L) watchHistoryIdForServer = newWh;

        // Title block
        String title = payload.optString("title", "");
        String subTitle = payload.optString("subtitle", "");
        if (titleText != null) titleText.setText(title);
        if (subtitleText != null) {
            if (subTitle != null && !subTitle.isEmpty() && !"null".equals(subTitle)) {
                subtitleText.setText(subTitle);
                subtitleText.setVisibility(View.VISIBLE);
            } else {
                subtitleText.setVisibility(View.GONE);
            }
        }

        // Repopulate audio + subtitle lists from the new payload (track switch
        // returns a new payload with updated activeAudioIndex / activeSubtitleIndex).
        populateAudioList();
        populateSubtitleList();
        updateDebugOverlay();

        // Build & prepare the media source
        String streamUrl = payload.optString("streamUrl", null);
        String hlsUrl = payload.optString("hlsUrl", null);
        String subtitleUrl = payload.isNull("subtitleUrl") ? null : payload.optString("subtitleUrl", null);
        boolean isBitmapSubtitle = payload.optBoolean("isBitmapSubtitle", false);

        boolean isDirectPlay = "direct_play".equals(strategy);
        String mediaUrl = isDirectPlay ? (streamUrl != null ? streamUrl : hlsUrl) : (hlsUrl != null ? hlsUrl : streamUrl);
        if (mediaUrl == null || mediaUrl.isEmpty()) {
            Log.w(TAG, "loadFromPayload: no URL");
            return;
        }

        MediaItem.Builder itemBuilder = new MediaItem.Builder().setUri(Uri.parse(mediaUrl));
        if (isDirectPlay) {
            double startTime = payload.optDouble("startTime", 0d);
            if (startTime > 0d) {
                itemBuilder.setClippingConfiguration(new MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs((long) (startTime * 1000d))
                        .build());
            }
        }
        // Find the active subtitle stream's language so we can pin the
        // SubtitleConfiguration to it — improves the chance the default
        // track selector picks it up.
        String subtitleLanguage = activeSubtitleLanguage(payload);
        if (subtitleUrl != null && !subtitleUrl.isEmpty() && !isBitmapSubtitle) {
            MediaItem.SubtitleConfiguration.Builder subBuilder =
                    new MediaItem.SubtitleConfiguration.Builder(Uri.parse(subtitleUrl))
                            .setMimeType(MimeTypes.TEXT_VTT)
                            .setSelectionFlags(C.SELECTION_FLAG_DEFAULT);
            if (subtitleLanguage != null && !subtitleLanguage.isEmpty()) {
                subBuilder.setLanguage(subtitleLanguage);
            }
            itemBuilder.setSubtitleConfigurations(java.util.Collections.singletonList(subBuilder.build()));
            Log.i(TAG, "loadFromPayload: attaching subtitle url=" + subtitleUrl
                    + " lang=" + subtitleLanguage);
        } else {
            Log.i(TAG, "loadFromPayload: no text subtitle (subtitleUrl="
                    + (subtitleUrl == null ? "null" : "set")
                    + ", isBitmapSubtitle=" + isBitmapSubtitle + ")");
        }

        MediaItem item = itemBuilder.build();

        // Detect subtitle-only updates so we don't reset playback position
        // when the user just changes a text subtitle. Audio/seek changes
        // come back with a NEW hls/stream URL because the server restarts
        // ffmpeg; subtitle changes only swap the subtitleUrl.
        boolean primaryUrlChanged =
                !equalsNullable(currentHlsUrl, hlsUrl) ||
                !equalsNullable(currentStreamUrl, streamUrl);
        boolean subtitleOnly = isUpdate && !primaryUrlChanged;

        if (subtitleOnly) {
            player.replaceMediaItem(0, item);
            // Position preserved; if the player was paused, keep it paused.
        } else {
            DefaultDataSource.Factory dsf = new DefaultDataSource.Factory(this);
            MediaSource ms = isDirectPlay
                    ? new ProgressiveMediaSource.Factory(dsf).createMediaSource(item)
                    : new HlsMediaSource.Factory(dsf).setAllowChunklessPreparation(true).createMediaSource(item);

            player.setMediaSource(ms, /* resetPosition */ true);
            player.prepare();
            player.play();
        }

        currentHlsUrl = hlsUrl;
        currentStreamUrl = streamUrl;
        currentSubtitleUrl = subtitleUrl;

        // Force the renderer to enable the text track when one is configured.
        // Without this, ExoPlayer can leave text disabled if the previous
        // session had no subtitles.
        boolean haveText = subtitleUrl != null && !subtitleUrl.isEmpty() && !isBitmapSubtitle;
        TrackSelectionParameters.Builder tspb = player.getTrackSelectionParameters().buildUpon();
        tspb.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !haveText);
        if (haveText && subtitleLanguage != null && !subtitleLanguage.isEmpty()) {
            tspb.setPreferredTextLanguage(subtitleLanguage);
        }
        player.setTrackSelectionParameters(tspb.build());

        kickInteraction();
    }

    private static boolean equalsNullable(String a, String b) {
        if (a == null) return b == null;
        return a.equals(b);
    }

    /** Look up the language of the active subtitle in the payload. */
    private String activeSubtitleLanguage(JSObject payload) {
        if (payload.isNull("activeSubtitleIndex")) return null;
        int idx = payload.optInt("activeSubtitleIndex", -1);
        if (idx < 0) return null;
        JSONArray streams = optArray(payload, "subtitleStreams");
        if (streams == null) return null;
        for (int i = 0; i < streams.length(); i++) {
            try {
                JSONObject s = streams.getJSONObject(i);
                if (s.optInt("index", -2) == idx) {
                    String lang = s.optString("language", "");
                    return (!lang.isEmpty() && !"und".equals(lang)) ? lang : null;
                }
            } catch (JSONException ignored) {}
        }
        return null;
    }

    /**
     * Seek by `deltaMs` from either the current playback position or, if
     * the user is mid-debounce, from the pending target. Each LEFT/RIGHT
     * press accumulates into {@link #pendingSeekTarget} and the actual
     * commit (local seek for direct_play, server round-trip for HLS) waits
     * for {@link #SEEK_DEBOUNCE_MS} of idle. The seek bar updates
     * immediately so the user sees where they're scrubbing to.
     */
    private void handleSeekStep(long deltaMs) {
        if (player == null) return;
        double from = pendingSeekTarget >= 0d ? pendingSeekTarget : getCurrentSeconds();
        double duration = getDurationSeconds();
        double target = Math.max(0d, from + (deltaMs / 1000d));
        if (duration > 0d) target = Math.min(target, duration);
        pendingSeekTarget = target;

        // Visual feedback: snap the seek bar / time text to the pending
        // target right now. The next UI tick will pick up `pendingSeekTarget`
        // via formatPosition().
        applyTimeUiNow();

        // Reset the debounce timer.
        uiHandler.removeCallbacks(commitSeekRunnable);
        uiHandler.postDelayed(commitSeekRunnable, SEEK_DEBOUNCE_MS);
    }

    private void commitPendingSeek() {
        if (player == null) return;
        if (pendingSeekTarget < 0d) return;
        double target = pendingSeekTarget;
        // IMPORTANT: do NOT reset pendingSeekTarget here. The HLS round-trip
        // takes 5-10s and during that time getCurrentSeconds() still reads
        // the OLD position. If we cleared the target now, the UI tick would
        // immediately render the old position, making the seek bar visibly
        // jump back to where it was, then jump forward again when
        // loadFromPayload finally lands. Keep the target set; onUiTick
        // clears it once the player's actual position matches.
        boolean isDirectPlay = "direct_play".equals(strategy);
        if (isDirectPlay) {
            long ms = (long) (target * 1000d);
            long duration = player.getDuration();
            if (duration > 0L) ms = Math.min(ms, duration);
            player.seekTo(Math.max(0L, ms));
            // Local seek is instant — onUiTick will see actual ≈ target on
            // the very next tick and clear pendingSeekTarget itself.
            return;
        }
        // Transcoded HLS — round-trip to JS so the server restarts ffmpeg.
        JSObject ev = new JSObject();
        ev.put("sessionId", sessionId);
        ev.put("absoluteTime", target);
        emit("requestSeek", ev);
    }

    /** Bypass the periodic UI tick to update time / progress immediately. */
    private void applyTimeUiNow() {
        if (player == null) return;
        double cur = pendingSeekTarget >= 0d ? pendingSeekTarget : getCurrentSeconds();
        double dur = getDurationSeconds();
        if (elapsedText != null) elapsedText.setText(formatTime(cur));
        if (remainingText != null) remainingText.setText("-" + formatTime(Math.max(0d, dur - cur)));
        if (seekBar != null && dur > 0d) {
            seekBar.setProgress((int) ((cur / dur) * 10000d));
        }
    }

    // ── TV mode state machine ────────────────────────────────────────

    private void setTvMode(TvMode mode) {
        tvMode = mode;
        // Cancel auto-hide while in a panel; restart it on return to seek.
        if (mode == TvMode.SEEK) {
            kickInteraction();
        }
        applyMode();
    }

    private void applyMode() {
        boolean inSeek = tvMode == TvMode.SEEK;
        boolean inAudio = tvMode == TvMode.AUDIO;
        boolean inSubs = tvMode == TvMode.SUBTITLES;

        topPanel.setVisibility(inSeek && controlsVisible() ? View.VISIBLE : View.GONE);
        bottomPanel.setVisibility(inSeek && controlsVisible() ? View.VISIBLE : View.GONE);
        audioPanel.setVisibility(inAudio ? View.VISIBLE : View.GONE);
        subtitlePanel.setVisibility(inSubs ? View.VISIBLE : View.GONE);

        if (hintText != null && inSeek) {
            hintText.setText("◀ ▶ Seek    OK Play/Pause    ▲ Audio    ▼ Subtitles");
        }

        if (inAudio) focusFirstChild(audioList);
        if (inSubs) focusFirstChild(subtitleList);

        updateCenterPanel();
    }

    private boolean controlsVisible() {
        if (player == null) return true;
        if (!player.isPlaying()) return true;
        return System.currentTimeMillis() - lastInteractionMs < CONTROLS_HIDE_DELAY_MS;
    }

    private void kickInteraction() {
        lastInteractionMs = System.currentTimeMillis();
        if (tvMode == TvMode.SEEK) {
            topPanel.setVisibility(View.VISIBLE);
            bottomPanel.setVisibility(View.VISIBLE);
        }
    }

    private void focusFirstChild(LinearLayout list) {
        if (list == null) return;
        list.post(() -> {
            for (int i = 0; i < list.getChildCount(); i++) {
                View child = list.getChildAt(i);
                if (child.isFocusable()) { child.requestFocus(); return; }
            }
        });
    }

    // ── audio list ────────────────────────────────────────────────────

    private void populateAudioList() {
        if (audioList == null) return;
        audioList.removeAllViews();

        // direct_play: enumerate ExoPlayer's discovered audio track groups.
        // Switching tracks is a local TrackSelectionOverride — no server
        // round-trip, no rebuffer.
        if (isDirectPlayStrategy() && lastTracks != null) {
            populateAudioListFromTracks();
            return;
        }

        if (lastPayload == null) return;
        JSONArray streams = optArray(lastPayload, "audioStreams");
        Log.i(TAG, "populateAudioList: streams=" + (streams == null ? "null" : streams.length()));
        if (streams == null || streams.length() == 0) {
            // Single placeholder: no audio.
            audioList.addView(buildTrackRow("✓", "(none)", null));
            return;
        }
        int activeIndex = lastPayload.optInt("activeAudioIndex", -1);
        for (int i = 0; i < streams.length(); i++) {
            JSONObject s;
            try { s = streams.getJSONObject(i); }
            catch (JSONException e) {
                Log.w(TAG, "populateAudioList: skipped index " + i + " — " + e.getMessage());
                continue;
            }
            int idx = s.optInt("index", -1);
            String label = audioLabel(s);
            Log.i(TAG, "populateAudioList[" + i + "] idx=" + idx + " label=" + label);
            boolean isActive = idx == activeIndex;
            View row = buildTrackRow(isActive ? "✓" : "", label, () -> onAudioPicked(idx));
            audioList.addView(row);
        }
    }

    private void populateAudioListFromTracks() {
        int rendered = 0;
        for (Tracks.Group group : lastTracks.getGroups()) {
            if (group.getType() != C.TRACK_TYPE_AUDIO) continue;
            TrackGroup tg = group.getMediaTrackGroup();
            for (int t = 0; t < tg.length; t++) {
                androidx.media3.common.Format f = tg.getFormat(t);
                String label = formatAudioLabel(f);
                boolean isActive = group.isTrackSelected(t);
                final TrackGroup finalGroup = tg;
                final int finalTrack = t;
                View row = buildTrackRow(isActive ? "✓" : "", label,
                        () -> applyLocalAudioOverride(finalGroup, finalTrack));
                audioList.addView(row);
                rendered++;
            }
        }
        Log.i(TAG, "populateAudioListFromTracks: rendered " + rendered + " audio tracks from ExoPlayer");
    }

    private static String formatAudioLabel(androidx.media3.common.Format f) {
        StringBuilder lbl = new StringBuilder();
        String mime = f.sampleMimeType != null ? f.sampleMimeType : "";
        // "audio/eac3" → "EAC3", "audio/raw" + label → label
        String codec = mime.replaceFirst("^audio/", "").toUpperCase();
        if (codec.isEmpty() && f.label != null) codec = f.label;
        if (codec.isEmpty()) codec = "?";
        lbl.append(codec);
        if (f.channelCount > 0) lbl.append(' ').append(f.channelCount).append("ch");
        String lang = f.language;
        if (lang != null && !lang.isEmpty() && !"und".equals(lang)) {
            lbl.append(" — ").append(lang);
        }
        if (f.label != null && !f.label.isEmpty()) {
            lbl.append(" (").append(f.label).append(')');
        }
        return lbl.toString();
    }

    private void applyLocalAudioOverride(TrackGroup group, int trackIndex) {
        if (player == null) return;
        TrackSelectionParameters.Builder b = player.getTrackSelectionParameters().buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
                .setOverrideForType(new TrackSelectionOverride(group, trackIndex));
        player.setTrackSelectionParameters(b.build());
        Log.i(TAG, "applyLocalAudioOverride: switched to track " + trackIndex);
        setTvMode(TvMode.SEEK);
        // The Tracks listener will repopulate the picker with the new active.
    }

    private void onAudioPicked(int audioStreamIndex) {
        // Same round-trip pattern as the WebView TV player: emit the request,
        // JS calls /api/playback/switch_audio, returns new HLS URL via
        // updateStream() — populateAudioList re-runs from the new payload
        // and the checkmark moves.
        JSObject ev = new JSObject();
        ev.put("sessionId", sessionId);
        ev.put("audioStreamIndex", audioStreamIndex);
        ev.put("currentVideoTime", player != null ? player.getCurrentPosition() / 1000d : 0d);
        emit("requestAudioSwitch", ev);
        setTvMode(TvMode.SEEK);
    }

    private static String audioLabel(JSONObject s) {
        String codec = s.optString("codec", "?").toUpperCase();
        int channels = s.optInt("channels", 0);
        String lang = s.optString("language", "");
        StringBuilder lbl = new StringBuilder();
        lbl.append(codec).append(' ').append(channels).append("ch");
        if (!"und".equals(lang) && !lang.isEmpty()) lbl.append(" — ").append(lang);
        String title = s.optString("title", "");
        if (!"null".equals(title) && !title.isEmpty()) lbl.append(" (").append(title).append(')');
        return lbl.toString();
    }

    // ── subtitle list ─────────────────────────────────────────────────

    private void populateSubtitleList() {
        if (subtitleList == null) return;
        subtitleList.removeAllViews();

        if (isDirectPlayStrategy() && lastTracks != null) {
            populateSubtitleListFromTracks();
            return;
        }

        if (lastPayload == null) return;
        JSONArray streams = optArray(lastPayload, "subtitleStreams");
        Log.i(TAG, "populateSubtitleList: streams=" + (streams == null ? "null" : streams.length()));
        boolean hasAny = streams != null && streams.length() > 0;
        boolean activeNull = lastPayload.isNull("activeSubtitleIndex");
        int activeIndex = activeNull ? -1 : lastPayload.optInt("activeSubtitleIndex", -1);
        boolean isBitmap = lastPayload.optBoolean("isBitmapSubtitle", false);

        // Off row (always)
        boolean offSelected = activeNull || activeIndex < 0;
        subtitleList.addView(buildTrackRow(offSelected ? "✓" : "", "Off",
                () -> onSubtitlePicked(null, false)));

        if (hasAny) {
            for (int i = 0; i < streams.length(); i++) {
                JSONObject s;
                try { s = streams.getJSONObject(i); }
                catch (JSONException e) { continue; }
                int idx = s.optInt("index", -1);
                boolean text = s.optBoolean("isText", true);
                boolean active = idx == activeIndex;
                String label = subtitleLabel(s);
                if (!text) label += " (Bitmap)";
                final int finalIdx = idx;
                final boolean finalText = text;
                subtitleList.addView(buildTrackRow(active ? "✓" : "", label,
                        () -> onSubtitlePicked(finalIdx, !finalText)));
            }
        }
    }

    private void populateSubtitleListFromTracks() {
        // "Off" row — disables text track type entirely.
        boolean anyTextSelected = lastTracks.isTypeSelected(C.TRACK_TYPE_TEXT);
        subtitleList.addView(buildTrackRow(anyTextSelected ? "" : "✓", "Off",
                this::applyLocalSubtitleOff));

        int rendered = 0;
        for (Tracks.Group group : lastTracks.getGroups()) {
            if (group.getType() != C.TRACK_TYPE_TEXT) continue;
            TrackGroup tg = group.getMediaTrackGroup();
            for (int t = 0; t < tg.length; t++) {
                androidx.media3.common.Format f = tg.getFormat(t);
                String label = formatSubtitleLabel(f);
                boolean isActive = group.isTrackSelected(t);
                final TrackGroup finalGroup = tg;
                final int finalTrack = t;
                View row = buildTrackRow(isActive ? "✓" : "", label,
                        () -> applyLocalSubtitleOverride(finalGroup, finalTrack));
                subtitleList.addView(row);
                rendered++;
            }
        }
        Log.i(TAG, "populateSubtitleListFromTracks: rendered " + rendered + " subtitle tracks");
    }

    private static String formatSubtitleLabel(androidx.media3.common.Format f) {
        StringBuilder lbl = new StringBuilder();
        String lang = f.language;
        if (lang != null && !lang.isEmpty() && !"und".equals(lang)) {
            lbl.append(lang.toUpperCase());
        } else {
            lbl.append("Subtitles");
        }
        String mime = f.sampleMimeType != null ? f.sampleMimeType : "";
        String codec = mime.replaceFirst("^application/", "").toUpperCase();
        if (!codec.isEmpty() && !codec.equals(lbl.toString().toUpperCase())) {
            lbl.append(" — ").append(codec);
        }
        if (f.label != null && !f.label.isEmpty()) {
            lbl.append(" (").append(f.label).append(')');
        }
        // ExoPlayer's PgsParser handles application/pgs natively; the row
        // works the same as text subs from the user's perspective.
        return lbl.toString();
    }

    private void applyLocalSubtitleOverride(TrackGroup group, int trackIndex) {
        if (player == null) return;
        TrackSelectionParameters.Builder b = player.getTrackSelectionParameters().buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setOverrideForType(new TrackSelectionOverride(group, trackIndex));
        player.setTrackSelectionParameters(b.build());
        Log.i(TAG, "applyLocalSubtitleOverride: switched to subtitle track " + trackIndex);
        setTvMode(TvMode.SEEK);
    }

    private void applyLocalSubtitleOff() {
        if (player == null) return;
        TrackSelectionParameters.Builder b = player.getTrackSelectionParameters().buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
                .clearOverridesOfType(C.TRACK_TYPE_TEXT);
        player.setTrackSelectionParameters(b.build());
        Log.i(TAG, "applyLocalSubtitleOff");
        setTvMode(TvMode.SEEK);
    }

    private boolean isDirectPlayStrategy() {
        return "direct_play".equals(strategy);
    }

    private void onSubtitlePicked(@Nullable Integer streamIndex, boolean isBitmap) {
        JSObject ev = new JSObject();
        ev.put("sessionId", sessionId);
        ev.put("subtitleStreamIndex", streamIndex == null ? -1 : streamIndex);
        ev.put("isBitmap", isBitmap);
        ev.put("currentVideoTime", player != null ? player.getCurrentPosition() / 1000d : 0d);
        emit("requestSubtitleSwitch", ev);
        setTvMode(TvMode.SEEK);
    }

    private static String subtitleLabel(JSONObject s) {
        String lang = s.optString("language", "");
        String codec = s.optString("codec", "");
        StringBuilder lbl = new StringBuilder();
        if (!"und".equals(lang) && !lang.isEmpty()) lbl.append(lang.toUpperCase());
        else lbl.append("Subtitles");
        if (!codec.isEmpty() && !"null".equals(codec)) lbl.append(" — ").append(codec.toUpperCase());
        return lbl.toString();
    }

    // ── row builder ───────────────────────────────────────────────────

    private View buildTrackRow(String check, String label, @Nullable Runnable onClick) {
        View row = LayoutInflater.from(this).inflate(R.layout.track_item, audioList, false);
        TextView checkView = row.findViewById(R.id.track_check);
        TextView labelView = row.findViewById(R.id.track_label);
        checkView.setText(check);
        labelView.setText(label);
        if (onClick != null) {
            row.setOnClickListener(v -> onClick.run());
            row.setOnKeyListener((v, keyCode, ev) -> {
                if (ev.getAction() == KeyEvent.ACTION_DOWN
                        && (keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                            || keyCode == KeyEvent.KEYCODE_ENTER)) {
                    onClick.run();
                    return true;
                }
                return false;
            });
        }
        return row;
    }

    // ── center pause / spinner ───────────────────────────────────────

    private void updateCenterPanel() {
        if (centerPanel == null || player == null) return;
        int state = player.getPlaybackState();
        boolean buffering = state == Player.STATE_BUFFERING;
        boolean paused = !player.isPlaying() && !buffering && state != Player.STATE_ENDED;

        if (buffering) {
            centerPanel.setVisibility(View.VISIBLE);
            centerSpinner.setVisibility(View.VISIBLE);
            centerPause.setVisibility(View.GONE);
        } else if (paused) {
            centerPanel.setVisibility(View.VISIBLE);
            centerSpinner.setVisibility(View.GONE);
            centerPause.setVisibility(View.VISIBLE);
        } else {
            centerPanel.setVisibility(View.GONE);
        }
    }

    /**
     * Show the centre spinner unconditionally — used during the stub-payload
     * window between Activity launch and the real updateStream() arrival.
     * onPlaybackStateChanged will take over once a media source is set.
     */
    private void showLoadingSpinner() {
        if (centerPanel == null) return;
        centerPanel.setVisibility(View.VISIBLE);
        if (centerSpinner != null) centerSpinner.setVisibility(View.VISIBLE);
        if (centerPause != null) centerPause.setVisibility(View.GONE);
    }

    // ── periodic UI tick ─────────────────────────────────────────────

    private void onUiTick() {
        if (player == null) return;

        // Clear the pending seek target once the player has actually arrived
        // there. Within ~2s tolerance to absorb buffering jitter and the
        // small offset between seekBase + position 0 and the precise target.
        if (pendingSeekTarget >= 0d) {
            double actual = getCurrentSeconds();
            if (Math.abs(actual - pendingSeekTarget) < 2d) {
                pendingSeekTarget = -1d;
            }
        }

        // Time + progress. While the user is mid-seek (pendingSeekTarget set),
        // show that target so the bar moves with each LEFT/RIGHT press
        // instead of waiting for the server round-trip.
        applyTimeUiNow();
        double dur = getDurationSeconds();

        // Fallback end-of-stream detection. Player.STATE_ENDED is the
        // primary signal, but for HLS event playlists ExoPlayer occasionally
        // stalls at the last segment instead of transitioning — the player
        // is no longer playing, no longer buffering, and the position is
        // pinned at duration. Treat that as ended so the auto-close /
        // play-next paths still fire.
        if (!ended && dur > 0d) {
            int state = player.getPlaybackState();
            boolean nearEnd = getCurrentSeconds() >= dur - 0.75d;
            boolean idle = state != Player.STATE_BUFFERING && !player.isPlaying();
            if (nearEnd && idle) {
                handleEndOfStream();
            }
        }

        // Auto-hide controls in seek mode while playing.
        if (tvMode == TvMode.SEEK) {
            boolean shouldShow = controlsVisible();
            int target = shouldShow ? View.VISIBLE : View.GONE;
            if (topPanel.getVisibility() != target) topPanel.setVisibility(target);
            if (bottomPanel.getVisibility() != target) bottomPanel.setVisibility(target);
        }

        uiHandler.postDelayed(uiTick, UI_TICK_MS);
    }

    private static String formatTime(double seconds) {
        if (seconds < 0) seconds = 0;
        long s = (long) Math.floor(seconds);
        long h = s / 3600;
        long m = (s % 3600) / 60;
        long sec = s % 60;
        if (h > 0) return String.format("%d:%02d:%02d", h, m, sec);
        return String.format("%d:%02d", m, sec);
    }

    // ── debug overlay ────────────────────────────────────────────────

    private void toggleDebugOverlay() { debugOverlayShown = !debugOverlayShown; updateDebugOverlay(); }

    private void updateDebugOverlay() {
        if (debugOverlay == null) return;
        if (!debugOverlayShown || lastPayload == null) {
            debugOverlay.setVisibility(View.GONE);
            return;
        }
        JSObject p = lastPayload;
        StringBuilder sb = new StringBuilder();
        sb.append('[').append(p.optString("strategy", "?").toUpperCase()).append(']');
        JSONObject video = p.has("video") && !p.isNull("video") ? p.optJSONObject("video") : null;
        if (video != null) {
            String transfer = video.optString("color_transfer", "");
            boolean hdr = "smpte2084".equals(transfer) || "arib-std-b67".equals(transfer);
            if (hdr) sb.append(" [HDR]");
            sb.append("\nvideo ").append(video.optString("codec", "?").toUpperCase());
            int w = video.optInt("width", 0);
            int h = video.optInt("height", 0);
            if (w > 0 && h > 0) sb.append(' ').append(w).append('×').append(h);
            String pixFmt = video.optString("pix_fmt", "");
            sb.append(pixFmt.contains("p10") || pixFmt.contains("p12") ? " 10-bit" : " 8-bit");
            if (!transfer.isEmpty() && !"null".equals(transfer)) sb.append(" / ").append(transfer);
        }
        long bitrate = p.optLong("bitrate", 0L);
        if (bitrate > 0) sb.append("\nsource ").append(String.format("%.1f Mbps", bitrate / 1_000_000d));
        JSONArray streams = optArray(p, "audioStreams");
        int activeIndex = p.optInt("activeAudioIndex", -1);
        if (streams != null) {
            for (int i = 0; i < streams.length(); i++) {
                try {
                    JSONObject s = streams.getJSONObject(i);
                    if (s.optInt("index", -2) == activeIndex) {
                        sb.append("\naudio ").append(s.optString("codec", "?").toUpperCase());
                        sb.append(' ').append(s.optInt("channels", 0)).append("ch");
                        String lang = s.optString("language", "");
                        if (!"und".equals(lang) && !lang.isEmpty()) sb.append(' ').append(lang);
                        break;
                    }
                } catch (JSONException ignored) {}
            }
        }
        debugOverlay.setText(sb.toString());
        debugOverlay.setVisibility(View.VISIBLE);
    }

    // ── helpers ───────────────────────────────────────────────────────

    /**
     * Capacitor's JSObject inherits from JSONObject; arrays come back as
     * raw JSONArray on opt(). We don't need JSArray's specific helpers, so
     * just hand back JSONArray directly. (My earlier conversion via
     * JSArray.from(String) silently failed because that overload doesn't
     * exist in Capacitor 6 — which is why audio + subtitle lists were
     * empty.)
     */
    private static JSONArray optArray(JSObject obj, String key) {
        Object v = obj.opt(key);
        if (v instanceof JSONArray) return (JSONArray) v;
        return null;
    }

    /**
     * Called once when playback hits the end of the stream — either via
     * Player.STATE_ENDED (normal path for direct_play and well-terminated
     * HLS event playlists) or the position-vs-duration fallback in
     * {@link #onUiTick} (covers HLS sessions where ENDLIST hasn't been
     * appended yet but the player has clearly run off the end).
     *
     * Movies self-finish after a short delay so the user lands back on the
     * MovieShow page even when the JS bridge is slow to deliver the
     * `ended` event. Episodes stay alive — JS responds to `ended` by
     * starting the next episode and calling updateStream() in-place.
     */
    private void handleEndOfStream() {
        if (ended) return;
        ended = true;
        stopProgressTimer();
        // Final position write (mark-watched path on the server).
        postProgressDirect();
        emit("ended", buildLifecycleEvent(null));

        boolean isMovie = movieIdForServer > 0L && episodeIdForServer == 0L;
        if (isMovie) {
            // Short delay so the JS bridge can also propagate `ended` →
            // closePlayer → setPlayerState(open=false) before the Activity
            // finishes; otherwise the WebView may briefly see a stale "open"
            // state and re-trigger the curtain when MainActivity resumes.
            uiHandler.postDelayed(() -> {
                if (!isFinishing()) finish();
            }, 1500L);
        }
    }

    // ── progress timer (10s for JS reportProgress) ───────────────────

    private void startProgressTimer() {
        progressHandler.removeCallbacks(progressTick);
        progressHandler.postDelayed(progressTick, PROGRESS_INTERVAL_MS);
    }
    private void stopProgressTimer() {
        if (progressHandler != null) progressHandler.removeCallbacks(progressTick);
    }
    private void emitProgress() {
        if (player == null) return;
        JSObject ev = new JSObject();
        ev.put("sessionId", sessionId);
        ev.put("position", getCurrentSeconds());
        ev.put("duration", getDurationSeconds());
        ev.put("isPlaying", player.isPlaying());
        emit("progress", ev);
        postProgressDirect();
        if (player.isPlaying()) {
            progressHandler.postDelayed(progressTick, PROGRESS_INTERVAL_MS);
        }
    }

    /**
     * POST current position to /api/playback/report_progress directly,
     * bypassing the JS bridge. See the comment on {@link #apiBase} for why.
     */
    private void postProgressDirect() {
        if (apiBase == null || apiBase.isEmpty()) return;
        if (episodeIdForServer <= 0L && movieIdForServer <= 0L) return;
        final long position = (long) getCurrentSeconds();
        final long duration = (long) getDurationSeconds();
        if (duration <= 0L) return;

        final String base = apiBase;
        final long ep = episodeIdForServer;
        final long mv = movieIdForServer;
        final long wh = watchHistoryIdForServer;

        httpExecutor.submit(() -> {
            HttpURLConnection conn = null;
            try {
                URL url = new URL(base + "/api/playback/report_progress");
                conn = (HttpURLConnection) url.openConnection();
                conn.setRequestMethod("POST");
                conn.setRequestProperty("Content-Type", "application/json");
                conn.setRequestProperty("Accept", "application/json");
                conn.setDoOutput(true);
                conn.setConnectTimeout(5000);
                conn.setReadTimeout(5000);

                JSONObject body = new JSONObject();
                body.put("time", position);
                body.put("duration", duration);
                if (ep > 0L) body.put("episode_id", ep);
                if (mv > 0L) body.put("movie_id", mv);
                if (wh > 0L) body.put("watch_history_id", wh);

                try (OutputStream os = conn.getOutputStream()) {
                    os.write(body.toString().getBytes(StandardCharsets.UTF_8));
                }
                int code = conn.getResponseCode();
                // Drain body so the underlying socket can be reused.
                try (InputStream is = code >= 400 ? conn.getErrorStream() : conn.getInputStream()) {
                    if (is != null) {
                        byte[] buf = new byte[1024];
                        while (is.read(buf) != -1) { /* discard */ }
                    }
                }
                if (code >= 400) {
                    Log.w(TAG, "report_progress HTTP " + code);
                }
            } catch (Exception e) {
                Log.w(TAG, "report_progress failed: " + e.getMessage());
            } finally {
                if (conn != null) conn.disconnect();
            }
        });
    }

    // ── event emit ────────────────────────────────────────────────────

    private void emit(String event, JSObject payload) {
        CarambaPlayerPlugin plugin = CarambaPlayerSession.pluginRef;
        if (plugin != null) plugin.emit(event, payload);
    }

    private JSObject buildLifecycleEvent(@Nullable String reason) {
        JSObject ev = new JSObject();
        ev.put("sessionId", sessionId);
        ev.put("position", getCurrentSeconds());
        ev.put("duration", getDurationSeconds());
        if (reason != null) ev.put("reason", reason);
        return ev;
    }
}
