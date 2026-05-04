package com.caramba.tv;

import com.getcapacitor.JSObject;

/**
 * Bridge between {@link CarambaPlayerPlugin} (the Capacitor plugin) and
 * {@link PlayerActivity} (the full-screen ExoPlayer surface).
 *
 * The plugin runs in the WebView's process and can't pass arbitrary objects
 * through {@link android.content.Intent} extras without serialising — JS
 * sends nested arrays/objects and we'd lose fidelity. So instead the plugin
 * stages the {@link com.getcapacitor.JSObject} payload here, launches the
 * Activity, and the Activity reads it back from this static holder.
 *
 * Once the Activity is alive, {@link #current} points at it so the plugin
 * can call {@link PlayerActivity#applyUpdate(JSObject)} mid-session (after
 * a server-side seek/audio-switch returned a new HLS URL) and so the
 * Activity can call back through {@link #pluginRef} to {@code notifyListeners}
 * for progress/seek/end/dismiss events.
 */
public final class CarambaPlayerSession {
    private CarambaPlayerSession() {}

    /** Payload set by the plugin before launching the Activity. */
    public static volatile JSObject pendingPayload;

    /** The live Activity, set in onCreate, cleared in onDestroy. */
    public static volatile PlayerActivity current;

    /** The plugin instance — used by the Activity to emit listener events. */
    public static volatile CarambaPlayerPlugin pluginRef;
}
