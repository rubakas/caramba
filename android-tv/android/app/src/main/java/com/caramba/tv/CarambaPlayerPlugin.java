package com.caramba.tv;

import android.content.Context;
import android.content.Intent;
import android.media.AudioFormat;
import android.os.Build;
import android.util.Log;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.exoplayer.audio.AudioCapabilities;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Capacitor plugin that hands playback off to a full-screen native
 * {@link PlayerActivity} backed by ExoPlayer (Media3).
 *
 * The plugin is intentionally dumb about the Rails contract — JS owns
 * session lifecycle (start/seek/switch/stop, prefs, progress reporting)
 * and uses this plugin as a "play this URL now" surface. When the Activity
 * needs the server (HLS seek, end-of-stream), it emits an event back to JS
 * via {@code notifyListeners}; JS hits Rails and calls {@link #updateStream}
 * with the new URL.
 *
 * Mirrors the structure of {@link CarambaUpdaterPlugin}: same registration
 * pattern (auto-discovered via {@code @CapacitorPlugin}), same web fallback
 * over in {@code android-tv/src/web.ts}.
 */
@CapacitorPlugin(name = "CarambaPlayer")
public class CarambaPlayerPlugin extends Plugin {
    private static final String TAG = "CarambaPlayer";

    @Override
    public void load() {
        super.load();
        CarambaPlayerSession.pluginRef = this;
        // Loud breadcrumb so it's obvious from `adb logcat` whether the
        // plugin actually registered. If you don't see this line at app
        // launch, the APK on the device is stale.
        Log.i(TAG, "load(): registered. device=" + Build.MODEL
                + " sdk=" + Build.VERSION.SDK_INT
                + " app=" + getContext().getPackageName());
    }

    @Override
    protected void handleOnDestroy() {
        if (CarambaPlayerSession.pluginRef == this) {
            CarambaPlayerSession.pluginRef = null;
        }
        super.handleOnDestroy();
    }

    /**
     * Feature-detect the native plugin from JS without try/catching every
     * method call. JS hits this once at app start and stores the result on
     * the capabilities object.
     */
    @PluginMethod
    public void isAvailable(PluginCall call) {
        JSObject result = new JSObject();
        result.put("available", true);
        call.resolve(result);
    }

    /**
     * Probes Media3's AudioCapabilities to discover which audio encodings
     * the device's full pipeline (HDMI / built-in DAC / connected AVR via
     * EDID) can actually accept. Sources whose audio codec isn't in this
     * list MUST be audio-transcoded by the server — Chromecast with Google
     * TV, for instance, never advertises DTS in EDID, so direct-playing a
     * DTS source resulted in ExoPlayer's AudioSink rejecting the format
     * (NO_UNSUPPORTED_TYPE) and silently selecting whatever fallback audio
     * the file happened to carry (e.g. AC3 commentary instead of DTS main).
     *
     * JS calls this once at app start (alongside isAvailable) and feeds
     * the result into buildAndroidTvProfile so the server's strategy is
     * grounded in real hardware state, not a static codec wishlist.
     */
    @PluginMethod
    public void getAudioCapabilities(PluginCall call) {
        try {
            AudioCapabilities caps = AudioCapabilities.getCapabilities(
                    getContext(),
                    new AudioAttributes.Builder()
                            .setUsage(C.USAGE_MEDIA)
                            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                            .build(),
                    /* routedDevice */ null);

            JSArray encodings = new JSArray();
            // PCM is always supported (it's the fallback). Listed for completeness.
            encodings.put("pcm_s16le");
            encodings.put("aac");
            encodings.put("mp3");
            encodings.put("flac");
            encodings.put("opus");
            encodings.put("vorbis");
            if (caps.supportsEncoding(AudioFormat.ENCODING_AC3))         encodings.put("ac3");
            if (caps.supportsEncoding(AudioFormat.ENCODING_E_AC3))       encodings.put("eac3");
            if (caps.supportsEncoding(AudioFormat.ENCODING_E_AC3_JOC))   encodings.put("eac3_joc");
            if (caps.supportsEncoding(AudioFormat.ENCODING_DTS))         encodings.put("dts");
            if (caps.supportsEncoding(AudioFormat.ENCODING_DTS_HD))      encodings.put("dtshd");
            if (caps.supportsEncoding(AudioFormat.ENCODING_DOLBY_TRUEHD)) {
                encodings.put("truehd");
                encodings.put("mlp");
            }

            JSObject result = new JSObject();
            result.put("supportedEncodings", encodings);
            result.put("maxChannelCount", caps.getMaxChannelCount());
            Log.i(TAG, "getAudioCapabilities: encodings=" + encodings.toString()
                    + " maxChannels=" + caps.getMaxChannelCount());
            call.resolve(result);
        } catch (Throwable t) {
            Log.w(TAG, "getAudioCapabilities failed; reporting conservative defaults", t);
            JSArray fallback = new JSArray();
            fallback.put("pcm_s16le");
            fallback.put("aac");
            fallback.put("mp3");
            JSObject result = new JSObject();
            result.put("supportedEncodings", fallback);
            result.put("maxChannelCount", 2);
            call.resolve(result);
        }
    }

    /**
     * Open the full-screen player. Stages the payload in
     * {@link CarambaPlayerSession#pendingPayload} and launches
     * {@link PlayerActivity}. Resolves immediately — playback is async.
     */
    @PluginMethod
    public void present(PluginCall call) {
        try {
            JSObject payload = mergeData(call);
            CarambaPlayerSession.pendingPayload = payload;

            Context ctx = getContext();
            Intent intent = new Intent(ctx, PlayerActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            ctx.startActivity(intent);

            call.resolve();
        } catch (Exception e) {
            Log.e(TAG, "present failed", e);
            call.reject("present failed: " + e.getMessage(), e);
        }
    }

    /**
     * Swap streamUrl/hlsUrl/subtitleUrl/seekBase mid-session. Called by JS
     * after the server has returned a new HLS URL (post-seek, post-audio-
     * switch, post-bitmap-subtitle-switch) or just a new subtitle URL
     * (post-text-subtitle-switch).
     *
     * If the Activity is dead (e.g. user backed out before the round-trip
     * completed), this is a no-op — the next {@link #present} call will pick
     * up the new payload.
     */
    @PluginMethod
    public void updateStream(PluginCall call) {
        try {
            final JSObject payload = mergeData(call);
            PlayerActivity activity = CarambaPlayerSession.current;
            if (activity == null) {
                // Race: JS sends present(stub) + updateStream(real) in quick
                // succession (typically <1s apart on a warm cache). On a
                // physical Chromecast the Activity's onCreate can take longer
                // than that gap to assign CarambaPlayerSession.current, so a
                // dropped updateStream left ExoPlayer idle with a 0:00 UI and
                // the title never started. Stash the latest payload so
                // PlayerActivity.onCreate picks it up via pendingPayload,
                // skips the pending:true branch, and loads the real media on
                // first try.
                CarambaPlayerSession.pendingPayload = payload;
                call.resolve();
                return;
            }
            activity.runOnUiThread(() -> activity.applyUpdate(payload));
            call.resolve();
        } catch (Exception e) {
            Log.e(TAG, "updateStream failed", e);
            call.reject("updateStream failed: " + e.getMessage(), e);
        }
    }

    @PluginMethod
    public void pause(PluginCall call) {
        PlayerActivity activity = CarambaPlayerSession.current;
        if (activity != null) {
            activity.runOnUiThread(activity::pausePlayback);
        }
        call.resolve();
    }

    @PluginMethod
    public void play(PluginCall call) {
        PlayerActivity activity = CarambaPlayerSession.current;
        if (activity != null) {
            activity.runOnUiThread(activity::resumePlayback);
        }
        call.resolve();
    }

    @PluginMethod
    public void seekTo(PluginCall call) {
        final double time = call.getDouble("time", 0d);
        PlayerActivity activity = CarambaPlayerSession.current;
        if (activity != null) {
            activity.runOnUiThread(() -> activity.seekToSeconds(time));
        }
        call.resolve();
    }

    /**
     * Finishes the Activity. JS calls this on {@code closePlayer} when the
     * UI initiated the dismissal (e.g. close button) — the user-back path
     * is the inverse: Activity finishes itself and emits {@code dismissed}
     * for JS to react to.
     */
    @PluginMethod
    public void dismiss(PluginCall call) {
        PlayerActivity activity = CarambaPlayerSession.current;
        if (activity != null) {
            activity.runOnUiThread(activity::finishFromJs);
        }
        call.resolve();
    }

    /**
     * One-shot query for the player's current position/duration. JS uses
     * this to read final time when the close was JS-initiated and the
     * {@code dismissed} listener wouldn't fire.
     */
    @PluginMethod
    public void getState(PluginCall call) {
        PlayerActivity activity = CarambaPlayerSession.current;
        JSObject result = new JSObject();
        if (activity == null) {
            result.put("position", 0);
            result.put("duration", 0);
            result.put("paused", true);
            result.put("ended", false);
        } else {
            result.put("position", activity.getCurrentSeconds());
            result.put("duration", activity.getDurationSeconds());
            result.put("paused", activity.isPaused());
            result.put("ended", activity.isEnded());
        }
        call.resolve(result);
    }

    /**
     * Forward an event from the Activity to JS listeners. Wraps
     * {@code notifyListeners} so {@link PlayerActivity} doesn't depend on
     * Capacitor types directly.
     */
    void emit(String event, JSObject payload) {
        notifyListeners(event, payload);
    }

    /**
     * Re-package a {@link PluginCall} into a fresh {@link JSObject} we can
     * stash safely — {@code call.getData()} returns a live view that can be
     * mutated by Capacitor between threads.
     */
    private JSObject mergeData(PluginCall call) {
        JSObject src = call.getData();
        JSObject copy = new JSObject();
        java.util.Iterator<String> keys = src.keys();
        while (keys.hasNext()) {
            String k = keys.next();
            copy.put(k, src.opt(k));
        }
        return copy;
    }
}
