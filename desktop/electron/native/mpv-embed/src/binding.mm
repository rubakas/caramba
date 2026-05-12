// Native binding that embeds libmpv playback into an Electron BrowserWindow.
//
// Approach: libmpv creates its own NSWindow (because mpv 0.41 macOS
// with libplacebo + Vulkan VO ignores the `wid` option and always
// makes its own surface); we reparent that window as a child of
// Electron's BrowserWindow, strip its decorations (borderless,
// non-movable), and lock its frame to Electron's content area. From
// the user's POV there's still effectively one window: Electron's.
//
// Why not mpv_render_context (the documented Electron-embed path)?
// I tried it and the libmpv build/setup doesn't produce frames into
// the CAOpenGLLayer FBO reliably — drawInCGLContext only fires twice
// and mpv never advances. Worth revisiting when we upgrade libmpv or
// can build with different options.
//
// Why not match Jellyfin Media Player's layout exactly? JMP is Qt +
// CEF, not Electron — JMP lets mpv own the NSWindow and embeds CEF on
// top as CAMetalLayers. Electron's BrowserWindow ownership doesn't
// invert, so we're stuck with the host-owns-window flavor.
//
// API surface exposed to JS:
//   mpvInit(nsViewBuffer, eventCb)     → throws on failure
//   mpvPlay(urlOrPath, options?)       → loadfile + start playback
//   mpvPause() / mpvResume() / mpvStop()
//   mpvSeek(seconds)                   → seek absolute
//   mpvGetState()                      → { time, duration, paused, playing, ended, error }
//   mpvGetTracks()                     → { audio: [...], subtitle: [...] }
//   mpvSetAudioTrack(id) / mpvSetSubtitleTrack(id)
//   mpvReparentAsChild(parentNsView)   → attach mpv's window as a
//                                        borderless child of parent
//   mpvSyncChildFrame(parentNsView)    → resync child frame on resize
//   mpvGetCapabilities()               → { decoders, demuxers }
//
// Single global mpv_handle at module scope; this matches Caramba's
// playback model (one active session at a time).

#include <napi.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGL/gl3.h>
#import <OpenGL/OpenGL.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <thread>
#include <atomic>

static mpv_handle* gMpv = nullptr;

// ── Event pump infrastructure ─────────────────────────────────────
//
// libmpv processes commands (loadfile, seek, set property) on its own
// internal threads but REQUIRES the host application to drain its event
// queue via mpv_wait_event. Without that drain, mpv's state machine
// stalls — FILE_LOADED never fires, property change events pile up,
// and commands appear to silently fail. JMP's design (referenced in
// jellyfin-desktop/src/main.cpp::mpv_digest_thread) uses a dedicated
// thread blocking on mpv_wait_event(-1) and dispatches events to the
// UI via the platform's main-thread queue.
//
// Here we marshal events back to JS via Napi::ThreadSafeFunction so the
// renderer / Electron main JS layer can drive UI state from real events
// instead of polling. The pump thread is started in mpvInit after
// mpv_initialize and joined in releaseMpv before mpv_terminate_destroy.
static Napi::ThreadSafeFunction gEventTsfn;
static std::thread gEventThread;
static std::atomic<bool> gEventStop{false};

// reply_userdata values for mpv_observe_property — these surface as
// `data->reply_userdata` on MPV_EVENT_PROPERTY_CHANGE so the dispatcher
// can map back to a property name without strcmp on every event.
enum ObservedProp : uint64_t {
    OBS_PAUSE = 1,
    OBS_TIME_POS,
    OBS_DURATION,
    OBS_CORE_IDLE,
    OBS_PAUSED_FOR_CACHE,
    OBS_SEEKING,
    OBS_EOF_REACHED,
    OBS_IDLE_ACTIVE,
};

// Event payload marshalled from pump thread → JS thread via tsfn.
struct EventMsg {
    std::string type;        // 'fileLoaded' | 'endFile' | 'property' | 'log' | 'shutdown' | 'startFile'
    std::string name;        // property name / log prefix
    std::string strValue;    // log text / end-file reason / property string value
    double      numValue;    // property numeric value
    bool        boolValue;   // property flag value
    bool        hasNum;
    bool        hasBool;
    bool        hasStr;
};

static void dispatchToJs(EventMsg* msg) {
    if (!gEventTsfn) { delete msg; return; }
    // NonBlockingCall — pump thread enqueues to JS thread without
    // waiting. BlockingCall would deadlock the pump when JS is busy
    // (e.g., the renderer is logging many state pushes), and mpv's
    // internal event queue would back up while pump waits — which
    // shows up to the user as a frozen UI.
    auto status = gEventTsfn.NonBlockingCall(msg, [](Napi::Env env, Napi::Function cb, EventMsg* m) {
        Napi::Object o = Napi::Object::New(env);
        o.Set("type", Napi::String::New(env, m->type));
        if (!m->name.empty())     o.Set("name",  Napi::String::New(env, m->name));
        if (m->hasNum)            o.Set("value", Napi::Number::New(env, m->numValue));
        if (m->hasBool)           o.Set("value", Napi::Boolean::New(env, m->boolValue));
        if (m->hasStr)            o.Set("value", Napi::String::New(env, m->strValue));
        if (!m->strValue.empty() && !m->hasStr)
                                  o.Set("text",  Napi::String::New(env, m->strValue));
        cb.Call({ o });
        delete m;
    });
    if (status != napi_ok) {
        delete msg;
    }
}

static void eventThreadMain() {
    while (!gEventStop.load(std::memory_order_relaxed)) {
        if (!gMpv) break;
        // -1 = block forever until an event arrives. Returns very fast
        // once events queue up (mpv_terminate_destroy publishes a
        // SHUTDOWN event that wakes us cleanly).
        mpv_event* ev = mpv_wait_event(gMpv, -1);
        if (!ev || ev->event_id == MPV_EVENT_NONE) continue;

        switch (ev->event_id) {
        case MPV_EVENT_SHUTDOWN: {
            auto* m = new EventMsg();
            m->type = "shutdown";
            dispatchToJs(m);
            return;
        }
        case MPV_EVENT_FILE_LOADED: {
            auto* m = new EventMsg();
            m->type = "fileLoaded";
            dispatchToJs(m);
            break;
        }
        case MPV_EVENT_START_FILE: {
            auto* m = new EventMsg();
            m->type = "startFile";
            dispatchToJs(m);
            break;
        }
        case MPV_EVENT_END_FILE: {
            auto* d = static_cast<mpv_event_end_file*>(ev->data);
            auto* m = new EventMsg();
            m->type = "endFile";
            // Translate mpv_end_file_reason → human-readable
            switch (d->reason) {
                case MPV_END_FILE_REASON_EOF:      m->strValue = "eof"; break;
                case MPV_END_FILE_REASON_STOP:     m->strValue = "stop"; break;
                case MPV_END_FILE_REASON_QUIT:     m->strValue = "quit"; break;
                case MPV_END_FILE_REASON_ERROR:    m->strValue = std::string("error: ") + mpv_error_string(d->error); break;
                case MPV_END_FILE_REASON_REDIRECT: m->strValue = "redirect"; break;
                default:                           m->strValue = "unknown"; break;
            }
            dispatchToJs(m);
            break;
        }
        case MPV_EVENT_LOG_MESSAGE: {
            auto* d = static_cast<mpv_event_log_message*>(ev->data);
            auto* m = new EventMsg();
            m->type = "log";
            m->name = d->prefix ? d->prefix : "";
            // strip trailing newline mpv adds
            std::string text = d->text ? d->text : "";
            if (!text.empty() && text.back() == '\n') text.pop_back();
            m->strValue = text;
            dispatchToJs(m);
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE: {
            auto* p = static_cast<mpv_event_property*>(ev->data);
            auto* m = new EventMsg();
            m->type = "property";
            switch (ev->reply_userdata) {
                case OBS_PAUSE:            m->name = "pause"; break;
                case OBS_TIME_POS:         m->name = "time-pos"; break;
                case OBS_DURATION:         m->name = "duration"; break;
                case OBS_CORE_IDLE:        m->name = "core-idle"; break;
                case OBS_PAUSED_FOR_CACHE: m->name = "paused-for-cache"; break;
                case OBS_SEEKING:          m->name = "seeking"; break;
                case OBS_EOF_REACHED:      m->name = "eof-reached"; break;
                case OBS_IDLE_ACTIVE:      m->name = "idle-active"; break;
                default:                   delete m; m = nullptr; break;
            }
            if (!m) break;
            if (p->format == MPV_FORMAT_DOUBLE && p->data) {
                m->numValue = *(double*)p->data; m->hasNum = true;
            } else if (p->format == MPV_FORMAT_FLAG && p->data) {
                m->boolValue = !!*(int*)p->data; m->hasBool = true;
            }
            // (MPV_FORMAT_NONE means property is unavailable — emit anyway
            // so JS can track unavailable state.)
            dispatchToJs(m);
            break;
        }
        default:
            // Many event kinds we don't care about; ignore.
            break;
        }
    }
}

// Pull NSView* out of the Buffer Electron returns from
// BrowserWindow.getNativeWindowHandle(). On macOS arm64 + x64 this is an
// 8-byte little-endian pointer to NSView (the BrowserWindow's contentView).
static NSView* nsviewFromBuffer(const Napi::Buffer<uint8_t>& buf) {
    if (buf.Length() != sizeof(void*)) return nil;
    void* p = nullptr;
    memcpy(&p, buf.Data(), sizeof(void*));
    return (__bridge NSView*)p;
}

static void releaseMpv() {
    // Stop the event thread first so it doesn't poll a soon-to-be-freed
    // handle. mpv_terminate_destroy posts MPV_EVENT_SHUTDOWN which wakes
    // mpv_wait_event with a return that lets the thread exit cleanly,
    // but as a belt-and-suspenders we set the stop flag too.
    gEventStop.store(true, std::memory_order_relaxed);
    if (gMpv) {
        mpv_wakeup(gMpv);
    }
    if (gEventThread.joinable()) {
        gEventThread.join();
    }
    if (gEventTsfn) {
        gEventTsfn.Release();
        gEventTsfn = Napi::ThreadSafeFunction();
    }


    if (gMpv) {
        mpv_terminate_destroy(gMpv);
        gMpv = nullptr;
    }
    gEventStop.store(false, std::memory_order_relaxed);
}

// Empty wakeup callback. Setting one signals to libmpv that an event
// consumer exists; the pump thread does the actual draining. Without
// the callback registered, libmpv may take internal shortcuts that
// silently swallow events.
static void onMpvWakeup(void*) { /* no-op; pump thread reads events */ }

// mpvInit(nsViewBuffer, eventCallback) — must be called once before mpvPlay.
//
// Configures libmpv for headless-Electron embed (no OSD, no keyboard /
// mouse input, modest cache), binds the "wid" option to the NSView
// pointer so mpv's video surface lives inside the BrowserWindow's view
// tree, registers a wakeup callback + property observations BEFORE
// mpv_initialize (JMP order, see jellyfin-desktop/src/main.cpp:742-753),
// and starts an event-pump thread that drains mpv's queue and forwards
// each event to the supplied JS callback.
static Napi::Value MpvInit(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "mpvInit(nsView: Buffer, eventCb: Function)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    if (info.Length() < 2 || !info[1].IsFunction()) {
        Napi::TypeError::New(env, "mpvInit requires an event callback function")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    NSView* view = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!view) {
        Napi::Error::New(env, "Invalid NSView buffer").ThrowAsJavaScriptException();
        return env.Null();
    }

    releaseMpv();
    gMpv = mpv_create();
    if (!gMpv) {
        Napi::Error::New(env, "mpv_create failed").ThrowAsJavaScriptException();
        return env.Null();
    }

    // Options set BEFORE mpv_initialize. Mirrors JMP handle.h:303–344
    // (input/OSD off, track-auto-selection off) plus libVLC-equivalent
    // caching for high-bitrate sources on NAS shares.
    mpv_set_option_string(gMpv, "osd-level", "0");
    mpv_set_option_string(gMpv, "osc", "no");
    mpv_set_option_string(gMpv, "input-default-bindings", "no");
    mpv_set_option_string(gMpv, "input-vo-keyboard", "no");
    mpv_set_option_string(gMpv, "input-vo-cursor", "no");
    mpv_set_option_string(gMpv, "input-cursor", "no");
    mpv_set_option_string(gMpv, "input-keyboard", "no");

    // Power-save / window:
    //   - stop-screensaver=no: host handles power blocking
    //   - force-window=no: mpv creates its NSWindow only when a file
    //     starts playing. mpv-embed-player.js polls for the window
    //     after loadfile and reparents it as a child of our
    //     BrowserWindow with no border / non-movable.
    //   - idle=yes: keep mpv alive between files.
    //   - ontop=no: child windows order via addChildWindow.
    //   - border=no: mpv's window is borderless from the start, so
    //     the brief moment before reparent doesn't show a title bar.
    mpv_set_option_string(gMpv, "stop-screensaver", "no");
    mpv_set_option_string(gMpv, "force-window", "no");
    mpv_set_option_string(gMpv, "idle", "yes");
    mpv_set_option_string(gMpv, "ontop", "no");
    mpv_set_option_string(gMpv, "border", "no");

    // Track selection — let mpv auto-pick tracks at FILE_LOADED.
    //
    // With track-auto-selection=no, mpv leaves ALL tracks at vid=no /
    // aid=no / sid=no and decode never starts (playback restart shows
    // `audio=eof, video=eof` immediately after the load-time seek).
    // JMP works around this by explicitly writing vid/aid/sid after
    // FILE_LOADED; until we replicate that pattern end-to-end the
    // safer default is to let mpv auto-pick a reasonable set, and have
    // the renderer override via mpvSetAudioTrack / mpvSetSubtitleTrack
    // when the server pre-selected a different track than mpv's
    // default (e.g. user-saved audio language).
    mpv_set_option_string(gMpv, "track-auto-selection", "yes");

    // Caching matched to libVLC's 5s — large enough to absorb NAS I/O
    // hiccups on 4K HEVC remuxes (~80 Mbps spikes), small enough that
    // seeks refill quickly.
    mpv_set_option_string(gMpv, "cache", "yes");
    mpv_set_option_string(gMpv, "cache-secs", "5");
    mpv_set_option_string(gMpv, "demuxer-max-bytes", "150MiB");
    mpv_set_option_string(gMpv, "demuxer-max-back-bytes", "75MiB");

    // Network-friendly: mpv lavf reconnect for HLS over flaky networks.
    mpv_set_option_string(gMpv, "stream-lavf-o-append",
        "reconnect=1,reconnect_streamed=1,reconnect_delay_max=2");

    // Embed: bind mpv's video output to our NSView. Cast NSView* → int64
    // for mpv's MPV_FORMAT_INT64 option type. On mpv 0.41 macOS with
    // libplacebo/Vulkan the wid is mostly ignored (mpv makes its own
    // window anyway), but setting it costs nothing and may help on
    // other libmpv builds.
    int64_t wid = (int64_t)(intptr_t)view;
    mpv_set_option(gMpv, "wid", MPV_FORMAT_INT64, &wid);

    // Register wakeup callback + property observations BEFORE
    // mpv_initialize (JMP main.cpp:742-748). The callback's presence
    // changes libmpv's queueing behavior; the observations cause
    // initial property values to arrive as events through the pump.
    mpv_set_wakeup_callback(gMpv, &onMpvWakeup, nullptr);
    mpv_observe_property(gMpv, OBS_PAUSE,            "pause",            MPV_FORMAT_FLAG);
    mpv_observe_property(gMpv, OBS_TIME_POS,         "time-pos",         MPV_FORMAT_DOUBLE);
    mpv_observe_property(gMpv, OBS_DURATION,         "duration",         MPV_FORMAT_DOUBLE);
    mpv_observe_property(gMpv, OBS_CORE_IDLE,        "core-idle",        MPV_FORMAT_FLAG);
    mpv_observe_property(gMpv, OBS_PAUSED_FOR_CACHE, "paused-for-cache", MPV_FORMAT_FLAG);
    mpv_observe_property(gMpv, OBS_SEEKING,          "seeking",          MPV_FORMAT_FLAG);
    mpv_observe_property(gMpv, OBS_EOF_REACHED,      "eof-reached",      MPV_FORMAT_FLAG);
    mpv_observe_property(gMpv, OBS_IDLE_ACTIVE,      "idle-active",      MPV_FORMAT_FLAG);

    int err = mpv_initialize(gMpv);
    if (err < 0) {
        std::string msg = std::string("mpv_initialize failed: ") + mpv_error_string(err);
        releaseMpv();
        Napi::Error::New(env, msg).ThrowAsJavaScriptException();
        return env.Null();
    }

    // Drain mpv's own diagnostics through MPV_EVENT_LOG_MESSAGE.
    // "info" is sufficient for production — surfaces VO selection,
    // load errors, and end-of-file reasons without flooding the
    // Electron main console. Bump to "v" or "debug" when diagnosing
    // playback / rendering issues.
    mpv_request_log_messages(gMpv, "info");

    // Spin up the JS-bound event pump. ThreadSafeFunction lets the
    // pump thread (any thread) call back into JS on the main thread.
    gEventStop.store(false, std::memory_order_relaxed);
    gEventTsfn = Napi::ThreadSafeFunction::New(
        env,
        info[1].As<Napi::Function>(),
        "mpv-event",
        0,    // unlimited queue
        1     // single producer thread
    );
    gEventThread = std::thread(eventThreadMain);

    return Napi::Boolean::New(env, true);
}

// mpvPlay(url, opts?) — opens URL/path, starts playback.
// opts.startTime in seconds (optional).
static Napi::Value MpvPlay(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!gMpv) {
        Napi::Error::New(env, "mpv not initialized; call mpvInit first")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "mpvPlay(url: string, opts?: {startTime})")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    std::string url = info[0].As<Napi::String>();
    double startTime = 0;
    if (info.Length() >= 2 && info[1].IsObject()) {
        Napi::Object opts = info[1].As<Napi::Object>();
        if (opts.Has("startTime")) {
            startTime = opts.Get("startTime").As<Napi::Number>().DoubleValue();
        }
    }

    // loadfile <url> replace <0|-1> <options-string>
    //
    // Load PAUSED. JMP's `LoadFile` (jellyfin-desktop/src/mpv/handle.h:161-216)
    // uses the same pattern: load paused, await FILE_LOADED on the event
    // pump, apply any deferred track-selection writes, then write
    // pause=false. JS callers `start()` resolve on the FILE_LOADED event
    // and unpause from there. Loading unpaused (`pause=no`) is the
    // documented mpv default but bypasses the chance to wait for tracks
    // to be enumerated before frames start flowing — JMP avoids it for
    // a reason and so should we.
    std::string optStr = "start=" + std::to_string(startTime) + ",pause=yes";
    const char* cmd[] = {
        "loadfile", url.c_str(), "replace", "-1", optStr.c_str(), nullptr
    };
    int err = mpv_command(gMpv, cmd);
    if (err < 0) {
        std::string msg = std::string("mpv loadfile failed: ") + mpv_error_string(err);
        Napi::Error::New(env, msg).ThrowAsJavaScriptException();
        return env.Null();
    }
    return Napi::Boolean::New(env, true);
}

static Napi::Value MpvPause(const Napi::CallbackInfo& info) {
    if (gMpv) {
        const char* val = "yes";
        mpv_set_property(gMpv, "pause", MPV_FORMAT_STRING, &val);
    }
    return info.Env().Undefined();
}

static Napi::Value MpvResume(const Napi::CallbackInfo& info) {
    if (gMpv) {
        const char* val = "no";
        mpv_set_property(gMpv, "pause", MPV_FORMAT_STRING, &val);
    }
    return info.Env().Undefined();
}

static Napi::Value MpvStop(const Napi::CallbackInfo& info) {
    if (gMpv) {
        const char* cmd[] = { "stop", nullptr };
        mpv_command(gMpv, cmd);
    }
    return info.Env().Undefined();
}

static Napi::Value MpvSeek(const Napi::CallbackInfo& info) {
    if (gMpv && info.Length() >= 1 && info[0].IsNumber()) {
        double s = info[0].As<Napi::Number>().DoubleValue();
        std::string s_str = std::to_string(s);
        const char* cmd[] = { "seek", s_str.c_str(), "absolute", nullptr };
        mpv_command_async(gMpv, 0, cmd);
    }
    return info.Env().Undefined();
}

static Napi::Value MpvGetState(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object out = Napi::Object::New(env);
    if (!gMpv) {
        out.Set("playing", Napi::Boolean::New(env, false));
        out.Set("paused", Napi::Boolean::New(env, false));
        out.Set("ended", Napi::Boolean::New(env, false));
        out.Set("error", Napi::Boolean::New(env, false));
        out.Set("time", Napi::Number::New(env, 0));
        out.Set("duration", Napi::Number::New(env, 0));
        return out;
    }
    double time = 0, duration = 0;
    int pauseFlag = 0, eofFlag = 0, idleFlag = 0;
    mpv_get_property(gMpv, "time-pos",    MPV_FORMAT_DOUBLE, &time);
    mpv_get_property(gMpv, "duration",    MPV_FORMAT_DOUBLE, &duration);
    mpv_get_property(gMpv, "pause",       MPV_FORMAT_FLAG,   &pauseFlag);
    mpv_get_property(gMpv, "eof-reached", MPV_FORMAT_FLAG,   &eofFlag);
    mpv_get_property(gMpv, "idle-active", MPV_FORMAT_FLAG,   &idleFlag);

    bool playing = !idleFlag && !pauseFlag && !eofFlag && duration > 0;
    out.Set("playing",  Napi::Boolean::New(env, playing));
    out.Set("paused",   Napi::Boolean::New(env, !!pauseFlag));
    out.Set("ended",    Napi::Boolean::New(env, !!eofFlag));
    out.Set("error",    Napi::Boolean::New(env, false));
    out.Set("time",     Napi::Number::New(env, time > 0 ? time : 0));
    out.Set("duration", Napi::Number::New(env, duration > 0 ? duration : 0));
    return out;
}

// Look up a string field from an MPV_FORMAT_NODE_MAP. Returns empty
// string if absent or wrong format.
static std::string nodeMapString(mpv_node* mapNode, const char* key) {
    if (mapNode->format != MPV_FORMAT_NODE_MAP) return "";
    for (int i = 0; i < mapNode->u.list->num; i++) {
        const char* k = mapNode->u.list->keys[i];
        mpv_node* v = &mapNode->u.list->values[i];
        if (k && strcmp(k, key) == 0 && v->format == MPV_FORMAT_STRING) {
            return v->u.string ? v->u.string : "";
        }
    }
    return "";
}

static int64_t nodeMapInt(mpv_node* mapNode, const char* key, int64_t fallback = -1) {
    if (mapNode->format != MPV_FORMAT_NODE_MAP) return fallback;
    for (int i = 0; i < mapNode->u.list->num; i++) {
        const char* k = mapNode->u.list->keys[i];
        mpv_node* v = &mapNode->u.list->values[i];
        if (k && strcmp(k, key) == 0 && v->format == MPV_FORMAT_INT64) {
            return v->u.int64;
        }
    }
    return fallback;
}

static Napi::Value MpvGetTracks(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object out = Napi::Object::New(env);
    Napi::Array audio = Napi::Array::New(env);
    Napi::Array subtitle = Napi::Array::New(env);
    out.Set("audio", audio);
    out.Set("subtitle", subtitle);
    if (!gMpv) return out;

    mpv_node node;
    int err = mpv_get_property(gMpv, "track-list", MPV_FORMAT_NODE, &node);
    if (err < 0) return out;

    if (node.format == MPV_FORMAT_NODE_ARRAY) {
        uint32_t ai = 0, si = 0;
        for (int i = 0; i < node.u.list->num; i++) {
            mpv_node* item = &node.u.list->values[i];
            std::string type = nodeMapString(item, "type");
            if (type != "audio" && type != "sub") continue;

            Napi::Object o = Napi::Object::New(env);
            o.Set("id",       Napi::Number::New(env, (double)nodeMapInt(item, "id", -1)));
            o.Set("title",    Napi::String::New(env, nodeMapString(item, "title")));
            o.Set("language", Napi::String::New(env, nodeMapString(item, "lang")));
            o.Set("codec",    Napi::String::New(env, nodeMapString(item, "codec")));
            o.Set("channels", Napi::Number::New(env,
                (double)nodeMapInt(item, "demux-channel-count", 0)));
            if (type == "audio") audio.Set(ai++, o);
            else                 subtitle.Set(si++, o);
        }
    }
    mpv_free_node_contents(&node);
    return out;
}

static Napi::Value MpvSetAudioTrack(const Napi::CallbackInfo& info) {
    if (gMpv && info.Length() >= 1 && info[0].IsNumber()) {
        int id = info[0].As<Napi::Number>().Int32Value();
        std::string s = (id < 0) ? "no" : std::to_string(id);
        const char* v = s.c_str();
        mpv_set_property(gMpv, "aid", MPV_FORMAT_STRING, &v);
    }
    return info.Env().Undefined();
}

static Napi::Value MpvSetSubtitleTrack(const Napi::CallbackInfo& info) {
    if (gMpv && info.Length() >= 1 && info[0].IsNumber()) {
        int id = info[0].As<Napi::Number>().Int32Value();
        std::string s = (id < 0) ? "no" : std::to_string(id);
        const char* v = s.c_str();
        mpv_set_property(gMpv, "sid", MPV_FORMAT_STRING, &v);
    }
    return info.Env().Undefined();
}

// MpvSendBehind: walks the BrowserWindow's NSView subview list, finds
// the mpv-created video subview, and re-orders it below Chromium's
// WebContents subview. Mirror of VlcSendBehind's class-prefix dance.
//
// mpv's macOS Cocoa video output names its subview "MpvVideoView" or
// similar (depends on vo backend). We identify it as anything that
// isn't a known Chromium / NSView default class — the embed view is
// added AFTER mpv_initialize so it's a new arrival in the subview list.
static Napi::Value MpvSendBehind(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "mpvSendBehind(parentNsView: Buffer)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) {
        Napi::Error::New(env, "Invalid NSView buffer").ThrowAsJavaScriptException();
        return env.Null();
    }

    __block int reordered = 0;
    void (^reorder)(void) = ^{
        NSArray<NSView*>* subs = [[parent subviews] copy];
        for (NSView* v in subs) {
            NSString* cls = NSStringFromClass([v class]);
            // Skip Chromium's view and standard NSView decorations.
            if ([cls hasPrefix:@"WebContents"]) continue;
            if ([cls hasPrefix:@"NSVisualEffect"]) continue;
            if ([cls isEqualToString:@"NSView"]) continue;
            if ([cls hasPrefix:@"NSTitlebar"]) continue;
            if ([cls hasPrefix:@"NSThemeFrame"]) continue;
            // Already at the bottom? No-op.
            if ([[parent subviews] firstObject] == v) {
                reordered = -1;
                return;
            }
            [v removeFromSuperview];
            [parent addSubview:v positioned:NSWindowBelow relativeTo:nil];
            reordered = 1;
            return;
        }
    };
    if ([NSThread isMainThread]) reorder();
    else dispatch_sync(dispatch_get_main_queue(), reorder);
    return Napi::Number::New(env, reordered);
}

// On mpv 0.41 with the libplacebo/Vulkan VO, setting `wid` to an
// NSView pointer no longer makes mpv attach its video output as a
// subview — the new GPU pipeline creates its own NSWindow regardless.
// The pragmatic workaround (the same model JMP uses internally) is to
// let mpv own its window and reparent it as a *child* of our
// BrowserWindow so it follows the parent's geometry and z-order. The
// child window sits below Chromium's WebContents but above the desktop;
// Chromium's transparency lets the video show through where the React
// UI doesn't paint.
//
// MpvReparentAsChild(parentNsView): walks NSApp.windows for the first
// orphan NSWindow that isn't the parent NSView's window or the
// detached DevTools window, makes it a child of the parent window
// ordered NSWindowBelow, hides its title bar, and sizes it to match
// the parent's content rect. Returns 1 if attached, 0 if no mpv
// window found yet, -1 if the parent NSView has no window.
static Napi::Value MpvReparentAsChild(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "mpvReparentAsChild(parentNsView: Buffer)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) {
        Napi::Error::New(env, "Invalid NSView buffer").ThrowAsJavaScriptException();
        return env.Null();
    }

    __block int outcome = 0;
    __block NSMutableArray<NSString*>* seen = [NSMutableArray array];
    void (^op)(void) = ^{
        NSWindow* parentWindow = [parent window];
        if (!parentWindow) { outcome = -1; return; }

        // Find mpv's VO window. mpv's NSWindow on macOS is a custom
        // subclass — the class name typically starts with "MPVWindow".
        // To survive class-name drift we collect everything we see and
        // surface to JS for diagnosis on miss.
        NSWindow* mpvWindow = nil;
        for (NSWindow* w in [NSApp windows]) {
            if (w == parentWindow) {
                [seen addObject:@"<parent>"];
                continue;
            }
            if (w.parentWindow == parentWindow) {
                outcome = 1;
                return;       // already a child of ours; nothing to do
            }
            NSString* className = NSStringFromClass([w class]);
            [seen addObject:[NSString stringWithFormat:@"%@%@", className,
                w.isVisible ? @"(vis)" : @"(hid)"]];
            // mpv 0.41+ on macOS uses a Swift-defined NSWindow whose
            // Objective-C class name is "swift.Window" (Swift mangles
            // its module name as a prefix). Older mpv builds used
            // "MPVWindow". Anything from Chromium / Electron has
            // distinct names we exclude.
            BOOL isMpvWindow =
                [className containsString:@"swift.Window"] ||
                [className hasPrefix:@"MPVWindow"];
            if (!isMpvWindow) continue;
            if (!w.isVisible) continue;
            mpvWindow = w;
            break;
        }
        if (!mpvWindow) {
            outcome = 0;
            fprintf(stderr, "[mpv-embed] reparent: no mpv window found; windows: %s\n",
                [[seen componentsJoinedByString:@", "] UTF8String]);
            return;
        }

        // Strip the standard window chrome (title bar, resize handle,
        // traffic lights, drag affordance) so the child window is
        // strictly a video surface. The user must perceive ONE window
        // — our BrowserWindow.
        mpvWindow.styleMask = NSWindowStyleMaskBorderless;
        mpvWindow.movable = NO;
        mpvWindow.hasShadow = NO;
        mpvWindow.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary
                                     | NSWindowCollectionBehaviorTransient;

        // Attach as a child of our BrowserWindow ordered BELOW.
        // Child windows follow the parent's move automatically and
        // get included in the parent's window list (so cmd-tab etc.
        // see only one app window).
        [parentWindow addChildWindow:mpvWindow ordered:NSWindowBelow];

        // Sync to the parent's CURRENT content rect (in screen coords),
        // and register notifications to re-sync whenever the parent
        // resizes or enters/leaves fullscreen. Parent move alone
        // doesn't need a sync — child windows follow that for free.
        NSRect contentRect = [parentWindow convertRectToScreen:
            [[parentWindow contentView] bounds]];
        [mpvWindow setFrame:contentRect display:NO];

        // Resync on parent resize: previously registered NSNotification
        // observers here, but they survive past Electron's window
        // teardown and dereference a deallocated parentWindow → hangs
        // on quit. The host calls mpvSyncChildFrame() from a
        // BrowserWindow 'resize' / 'will-enter-full-screen' /
        // 'leave-full-screen' listener in main.js instead, which can
        // be cleanly removed before window destruction.
        outcome = 1;
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return Napi::Number::New(env, outcome);
}

// Resize the (now-child) mpv window to match the parent's current
// content rect. Called on BrowserWindow `resize` / `move` events.
static Napi::Value MpvSyncChildFrame(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) return env.Undefined();
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) return env.Undefined();

    void (^op)(void) = ^{
        NSWindow* parentWindow = [parent window];
        if (!parentWindow) return;
        for (NSWindow* w in [parentWindow childWindows]) {
            NSRect contentRect = [parentWindow contentRectForFrameRect:parentWindow.frame];
            [w setFrame:contentRect display:YES];
        }
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return env.Undefined();
}

// Debug helper: returns the parent's subview class names, top to bottom.
static Napi::Value MpvDebugSubviews(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) return Napi::Array::New(env);
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) return Napi::Array::New(env);

    __block Napi::Array out = Napi::Array::New(env);
    void (^op)(void) = ^{
        NSArray<NSView*>* subs = [parent subviews];
        for (NSUInteger i = 0; i < subs.count; i++) {
            NSView* v = subs[(subs.count - 1 - i)];
            NSString* cls = NSStringFromClass([v class]);
            out.Set((uint32_t)i, Napi::String::New(env, [cls UTF8String]));
        }
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return out;
}

static Napi::Value MpvSetSubviewFrame(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 5) return env.Undefined();
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) return env.Undefined();
    double x = info[1].As<Napi::Number>().DoubleValue();
    double y = info[2].As<Napi::Number>().DoubleValue();
    double w = info[3].As<Napi::Number>().DoubleValue();
    double h = info[4].As<Napi::Number>().DoubleValue();
    void (^op)(void) = ^{
        NSArray<NSView*>* subs = [parent subviews];
        if (subs.count == 0) return;
        NSView* vout = [subs firstObject]; // already moved to back by MpvSendBehind
        [vout setFrame:NSMakeRect(x, y, w, h)];
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return env.Undefined();
}

// Pull ffmpeg codec names from an mpv decoder-list / encoder-list entry.
static void collectCodecNames(mpv_node* arrayNode, std::vector<std::string>& out) {
    if (arrayNode->format != MPV_FORMAT_NODE_ARRAY) return;
    for (int i = 0; i < arrayNode->u.list->num; i++) {
        mpv_node* item = &arrayNode->u.list->values[i];
        std::string codec = nodeMapString(item, "codec");
        if (!codec.empty()) out.push_back(codec);
    }
}

// mpvGetCapabilities — returns the raw mpv decoder/demuxer lists for
// the DeviceProfile builder. The JS-side device-profile.js classifies
// each codec by name into video/audio/subtitle and translates ffmpeg
// names to Jellyfin-style names (matroska → mkv, etc.).
static Napi::Value MpvGetCapabilities(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object out = Napi::Object::New(env);
    Napi::Array decoders = Napi::Array::New(env);
    Napi::Array demuxers = Napi::Array::New(env);
    out.Set("decoders", decoders);
    out.Set("demuxers", demuxers);
    if (!gMpv) return out;

    std::vector<std::string> decoderNames;
    mpv_node decoderNode;
    if (mpv_get_property(gMpv, "decoder-list", MPV_FORMAT_NODE, &decoderNode) >= 0) {
        collectCodecNames(&decoderNode, decoderNames);
        mpv_free_node_contents(&decoderNode);
    }
    uint32_t di = 0;
    for (const auto& name : decoderNames) {
        decoders.Set(di++, Napi::String::New(env, name));
    }

    mpv_node demuxerNode;
    if (mpv_get_property(gMpv, "demuxer-lavf-list", MPV_FORMAT_NODE, &demuxerNode) >= 0) {
        if (demuxerNode.format == MPV_FORMAT_NODE_ARRAY) {
            uint32_t mi = 0;
            for (int i = 0; i < demuxerNode.u.list->num; i++) {
                mpv_node* item = &demuxerNode.u.list->values[i];
                if (item->format == MPV_FORMAT_STRING && item->u.string) {
                    demuxers.Set(mi++, Napi::String::New(env, item->u.string));
                }
            }
        }
        mpv_free_node_contents(&demuxerNode);
    }

    return out;
}

// Process-exit cleanup. Without this, the event-pump thread keeps
// running after Electron tears down the JS environment, and any mpv
// event firing during teardown calls into a dead Napi env → segfault →
// the "process closed unexpectedly" report dialog macOS shows on
// crash. The hook fires before V8 disposes of the env so we can
// shut down cleanly.
static void OnEnvExit(void*) {
    releaseMpv();
}

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    napi_add_env_cleanup_hook(env, OnEnvExit, nullptr);
    exports.Set("mpvInit",             Napi::Function::New(env, MpvInit));
    exports.Set("mpvPlay",             Napi::Function::New(env, MpvPlay));
    exports.Set("mpvPause",            Napi::Function::New(env, MpvPause));
    exports.Set("mpvResume",           Napi::Function::New(env, MpvResume));
    exports.Set("mpvStop",             Napi::Function::New(env, MpvStop));
    exports.Set("mpvSeek",             Napi::Function::New(env, MpvSeek));
    exports.Set("mpvGetState",         Napi::Function::New(env, MpvGetState));
    exports.Set("mpvGetTracks",        Napi::Function::New(env, MpvGetTracks));
    exports.Set("mpvSetAudioTrack",    Napi::Function::New(env, MpvSetAudioTrack));
    exports.Set("mpvSetSubtitleTrack", Napi::Function::New(env, MpvSetSubtitleTrack));
    exports.Set("mpvSendBehind",       Napi::Function::New(env, MpvSendBehind));
    exports.Set("mpvSetSubviewFrame",  Napi::Function::New(env, MpvSetSubviewFrame));
    exports.Set("mpvDebugSubviews",    Napi::Function::New(env, MpvDebugSubviews));
    exports.Set("mpvReparentAsChild",  Napi::Function::New(env, MpvReparentAsChild));
    exports.Set("mpvSyncChildFrame",   Napi::Function::New(env, MpvSyncChildFrame));
    exports.Set("mpvGetCapabilities",  Napi::Function::New(env, MpvGetCapabilities));
    return exports;
}

NODE_API_MODULE(mpv_embed, Init)
