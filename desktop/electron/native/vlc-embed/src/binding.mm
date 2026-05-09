// Native binding that embeds libVLC playback into an Electron BrowserWindow.
//
// The renderer never touches libVLC. The Electron main process gets the
// BrowserWindow's NSView pointer via getNativeWindowHandle(), passes it
// down to vlcInit(), and from then on libVLC owns a child NSView inside
// that NSView for video output. The React UI continues to render via
// Chromium on top — Electron's BrowserWindow is created with
// `transparent: true` so the libVLC subview is visible underneath.
//
// API surface exposed to JS:
//   vlcInit(pluginPath, nsViewBuffer)  → throws on failure
//   vlcPlay(filepath, options?)        → opens the file and starts playback
//   vlcPause() / vlcResume() / vlcStop()
//   vlcSeek(seconds)                   → libvlc_media_player_set_time
//   vlcGetState()                      → { time, duration, paused, playing }
//   vlcSetAudioTrack(id) / vlcSetSubtitleTrack(id)
//   vlcGetTracks()                     → { audio: [...], subtitle: [...] }
//
// Single global libvlc_instance + media_player at module scope; this matches
// Caramba's playback model (one active session at a time).

#include <napi.h>
#import <Cocoa/Cocoa.h>
#include <vlc/vlc.h>
#include <stdlib.h>
#include <string.h>
#include <string>

static libvlc_instance_t* gVlc = nullptr;
static libvlc_media_player_t* gPlayer = nullptr;

// Pull NSView* out of the Buffer Electron returns from
// BrowserWindow.getNativeWindowHandle(). On macOS arm64 + x64 this is an
// 8-byte little-endian pointer to NSView (the BrowserWindow's contentView).
static NSView* nsviewFromBuffer(const Napi::Buffer<uint8_t>& buf) {
    if (buf.Length() != sizeof(void*)) return nil;
    void* p = nullptr;
    memcpy(&p, buf.Data(), sizeof(void*));
    return (__bridge NSView*)p;
}

static void releasePlayer() {
    if (gPlayer) {
        libvlc_media_player_stop(gPlayer);
        libvlc_media_player_release(gPlayer);
        gPlayer = nullptr;
    }
}

// vlcInit(pluginPath, nsViewBuffer) — must be called once before vlcPlay.
// Sets VLC_PLUGIN_PATH so libvlc finds its 300+ codec/demuxer plugins from
// our vendored bundle, NOT from any system VLC install.
static Napi::Value VlcInit(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 2 || !info[0].IsString() || !info[1].IsBuffer()) {
        Napi::TypeError::New(env, "vlcInit(pluginPath: string, nsView: Buffer)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    std::string pluginPath = info[0].As<Napi::String>();
    setenv("VLC_PLUGIN_PATH", pluginPath.c_str(), 1);

    if (gVlc) {
        releasePlayer();
        libvlc_release(gVlc);
        gVlc = nullptr;
    }

    // Run libvlc in quiet mode (--quiet) and keep the host responsible for
    // window/keyboard handling — no VLC HUD, no keyboard shortcut grabbing.
    //
    // Caching: libvlc's defaults (file=300ms, live=300ms, network=1000ms) are
    // far too small for the high-bitrate sources Caramba plays (4K HEVC remux
    // can spike past 80 Mbps). On a NAS share or under macOS App Nap, even
    // brief I/O hiccups drain the buffer and stall playback mid-stream. 5s
    // is large enough to absorb those hiccups but small enough that seeks
    // refill quickly. Mirrors the buffering hls.js gives the web/android path.
    const char* args[] = {
        "--quiet",
        "--no-video-title-show",
        "--no-snapshot-preview",
        "--no-osd",
        "--no-stats",
        "--no-keyboard-events",
        "--no-mouse-events",
        "--file-caching=5000",
        "--live-caching=5000",
        "--network-caching=5000",
        "--disc-caching=5000",
    };
    int argc = sizeof(args) / sizeof(args[0]);
    gVlc = libvlc_new(argc, args);
    if (!gVlc) {
        Napi::Error::New(env, "libvlc_new failed (check VLC_PLUGIN_PATH)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    return Napi::Boolean::New(env, true);
}

// vlcSetView(nsViewBuffer) — drawable for the next play call. Stored as a
// strong reference on the player; safe to call before vlcPlay.
static NSView* gPendingView = nil;
static Napi::Value VlcSetView(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "vlcSetView(nsView: Buffer)")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    gPendingView = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!gPendingView) {
        Napi::Error::New(env, "Invalid NSView buffer").ThrowAsJavaScriptException();
        return env.Null();
    }
    if (gPlayer) {
        libvlc_media_player_set_nsobject(gPlayer, (__bridge void*)gPendingView);
    }
    return Napi::Boolean::New(env, true);
}

// vlcPlay(filepath, opts?) — opens file, attaches to the previously-set
// NSView, starts playback. opts.startTime in seconds (optional).
static Napi::Value VlcPlay(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (!gVlc) {
        Napi::Error::New(env, "libvlc not initialized; call vlcInit first")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    if (info.Length() < 1 || !info[0].IsString()) {
        Napi::TypeError::New(env, "vlcPlay(filepath: string, opts?: {startTime})")
            .ThrowAsJavaScriptException();
        return env.Null();
    }
    std::string filepath = info[0].As<Napi::String>();
    int64_t startTimeMs = 0;
    if (info.Length() >= 2 && info[1].IsObject()) {
        Napi::Object opts = info[1].As<Napi::Object>();
        if (opts.Has("startTime")) {
            double s = opts.Get("startTime").As<Napi::Number>().DoubleValue();
            if (s > 0) startTimeMs = (int64_t)(s * 1000.0);
        }
    }

    releasePlayer();

    libvlc_media_t* media = libvlc_media_new_path(gVlc, filepath.c_str());
    if (!media) {
        Napi::Error::New(env, "libvlc_media_new_path failed").ThrowAsJavaScriptException();
        return env.Null();
    }
    gPlayer = libvlc_media_player_new_from_media(media);
    libvlc_media_release(media);
    if (!gPlayer) {
        Napi::Error::New(env, "libvlc_media_player_new_from_media failed").ThrowAsJavaScriptException();
        return env.Null();
    }

    if (gPendingView) {
        libvlc_media_player_set_nsobject(gPlayer, (__bridge void*)gPendingView);
    }
    libvlc_media_player_play(gPlayer);
    if (startTimeMs > 0) {
        // libvlc accepts time-set before the media is fully parsed; it's
        // applied as soon as playback starts.
        libvlc_media_player_set_time(gPlayer, startTimeMs);
    }
    return Napi::Boolean::New(env, true);
}

static Napi::Value VlcPause(const Napi::CallbackInfo& info) {
    if (gPlayer) libvlc_media_player_set_pause(gPlayer, 1);
    return info.Env().Undefined();
}
static Napi::Value VlcResume(const Napi::CallbackInfo& info) {
    if (gPlayer) libvlc_media_player_set_pause(gPlayer, 0);
    return info.Env().Undefined();
}
static Napi::Value VlcStop(const Napi::CallbackInfo& info) {
    releasePlayer();
    return info.Env().Undefined();
}
static Napi::Value VlcSeek(const Napi::CallbackInfo& info) {
    if (gPlayer && info.Length() >= 1 && info[0].IsNumber()) {
        double s = info[0].As<Napi::Number>().DoubleValue();
        libvlc_media_player_set_time(gPlayer, (int64_t)(s * 1000.0));
    }
    return info.Env().Undefined();
}

static Napi::Value VlcGetState(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object out = Napi::Object::New(env);
    if (!gPlayer) {
        out.Set("playing", Napi::Boolean::New(env, false));
        out.Set("paused", Napi::Boolean::New(env, false));
        out.Set("time", Napi::Number::New(env, 0));
        out.Set("duration", Napi::Number::New(env, 0));
        return out;
    }
    libvlc_state_t state = libvlc_media_player_get_state(gPlayer);
    int64_t timeMs = libvlc_media_player_get_time(gPlayer);
    int64_t durMs = libvlc_media_player_get_length(gPlayer);
    out.Set("playing", Napi::Boolean::New(env, state == libvlc_Playing));
    out.Set("paused",  Napi::Boolean::New(env, state == libvlc_Paused));
    out.Set("ended",   Napi::Boolean::New(env, state == libvlc_Ended));
    out.Set("error",   Napi::Boolean::New(env, state == libvlc_Error));
    out.Set("time",     Napi::Number::New(env, (double)(timeMs < 0 ? 0 : timeMs) / 1000.0));
    out.Set("duration", Napi::Number::New(env, (double)(durMs  < 0 ? 0 : durMs)  / 1000.0));
    return out;
}

// Build a JS array of {id, language, name} from a libvlc track description.
static Napi::Array trackDescriptionToJs(Napi::Env env, libvlc_track_description_t* head) {
    Napi::Array arr = Napi::Array::New(env);
    uint32_t i = 0;
    for (libvlc_track_description_t* t = head; t; t = t->p_next) {
        Napi::Object o = Napi::Object::New(env);
        o.Set("id", Napi::Number::New(env, t->i_id));
        o.Set("name", Napi::String::New(env, t->psz_name ? t->psz_name : ""));
        arr.Set(i++, o);
    }
    return arr;
}

static Napi::Value VlcGetTracks(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    Napi::Object out = Napi::Object::New(env);
    if (!gPlayer) {
        out.Set("audio", Napi::Array::New(env));
        out.Set("subtitle", Napi::Array::New(env));
        return out;
    }
    libvlc_track_description_t* a = libvlc_audio_get_track_description(gPlayer);
    libvlc_track_description_t* s = libvlc_video_get_spu_description(gPlayer);
    out.Set("audio", trackDescriptionToJs(env, a));
    out.Set("subtitle", trackDescriptionToJs(env, s));
    if (a) libvlc_track_description_list_release(a);
    if (s) libvlc_track_description_list_release(s);
    return out;
}

static Napi::Value VlcSetAudioTrack(const Napi::CallbackInfo& info) {
    if (gPlayer && info.Length() >= 1 && info[0].IsNumber()) {
        libvlc_audio_set_track(gPlayer, info[0].As<Napi::Number>().Int32Value());
    }
    return info.Env().Undefined();
}
static Napi::Value VlcSetSubtitleTrack(const Napi::CallbackInfo& info) {
    if (gPlayer && info.Length() >= 1 && info[0].IsNumber()) {
        libvlc_video_set_spu(gPlayer, info[0].As<Napi::Number>().Int32Value());
    }
    return info.Env().Undefined();
}

// libvlc_media_player_set_nsobject calls [parent addSubview:vout_view],
// which puts the video subview ON TOP of Chromium's WebContents subview.
// Re-order so libVLC's view sits behind Chromium, letting the React UI
// (with transparent body background) overlay the video.
//
// Identification: libvlc's vout subview is the one whose class name
// starts with "VLC". This is stable across libvlc 3.x. We use it instead
// of "the last subview" so retries are idempotent — calling
// vlcSendBehind twice in a row leaves Chromium ON TOP both times.
static Napi::Value VlcSendBehind(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "vlcSendBehind(parentNsView: Buffer)")
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
            if (![cls hasPrefix:@"VLC"]) continue;
            // Only reorder if this view isn't already the bottom-most.
            if ([[parent subviews] firstObject] == v) {
                reordered = -1;  // already at bottom
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

// Debug helper: returns the parent's subview class names, top to bottom.
// Useful when iterating on the embed without rebuilding repeatedly.
static Napi::Value VlcDebugSubviews(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) return Napi::Array::New(env);
    NSView* parent = nsviewFromBuffer(info[0].As<Napi::Buffer<uint8_t>>());
    if (!parent) return Napi::Array::New(env);

    __block Napi::Array out = Napi::Array::New(env);
    void (^op)(void) = ^{
        NSArray<NSView*>* subs = [parent subviews];
        for (NSUInteger i = 0; i < subs.count; i++) {
            NSView* v = subs[(subs.count - 1 - i)];  // top-most first
            NSString* cls = NSStringFromClass([v class]);
            out.Set((uint32_t)i, Napi::String::New(env, [cls UTF8String]));
        }
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return out;
}

static Napi::Value VlcSetSubviewFrame(const Napi::CallbackInfo& info) {
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
        NSView* vout = [subs firstObject]; // already moved to back by VlcSendBehind
        [vout setFrame:NSMakeRect(x, y, w, h)];
    };
    if ([NSThread isMainThread]) op();
    else dispatch_sync(dispatch_get_main_queue(), op);
    return env.Undefined();
}

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    exports.Set("vlcInit",            Napi::Function::New(env, VlcInit));
    exports.Set("vlcSetView",         Napi::Function::New(env, VlcSetView));
    exports.Set("vlcPlay",            Napi::Function::New(env, VlcPlay));
    exports.Set("vlcPause",           Napi::Function::New(env, VlcPause));
    exports.Set("vlcResume",          Napi::Function::New(env, VlcResume));
    exports.Set("vlcStop",            Napi::Function::New(env, VlcStop));
    exports.Set("vlcSeek",            Napi::Function::New(env, VlcSeek));
    exports.Set("vlcGetState",        Napi::Function::New(env, VlcGetState));
    exports.Set("vlcGetTracks",       Napi::Function::New(env, VlcGetTracks));
    exports.Set("vlcSetAudioTrack",   Napi::Function::New(env, VlcSetAudioTrack));
    exports.Set("vlcSetSubtitleTrack",Napi::Function::New(env, VlcSetSubtitleTrack));
    exports.Set("vlcSendBehind",      Napi::Function::New(env, VlcSendBehind));
    exports.Set("vlcSetSubviewFrame", Napi::Function::New(env, VlcSetSubviewFrame));
    exports.Set("vlcDebugSubviews",   Napi::Function::New(env, VlcDebugSubviews));
    return exports;
}

NODE_API_MODULE(vlc_embed, Init)
