// Native binding that embeds libmpv playback into an Electron BrowserWindow.
//
// The renderer never touches libmpv. The Electron main process gets the
// BrowserWindow's NSView pointer via getNativeWindowHandle(), passes it
// down to mpvInit(), and from then on libmpv owns a child surface inside
// that NSView for video output. The React UI continues to render via
// Chromium on top — Electron's BrowserWindow is created with
// `transparent: true` so the libmpv surface is visible underneath.
//
// Embedding flavor: Path 1 from the migration plan — the `wid` option
// set to the NSView pointer. mpv attempts to attach its video surface
// as a child of that NSView. If that misbehaves on a particular libmpv
// build (mpv pops its own window instead), the next fallback is to
// switch to mpv_render_context with a CAMetalLayer (Path 2).
//
// API surface exposed to JS:
//   mpvInit(nsViewBuffer)              → throws on failure
//   mpvPlay(urlOrPath, options?)       → loadfile + start playback
//   mpvPause() / mpvResume() / mpvStop()
//   mpvSeek(seconds)                   → seek absolute
//   mpvGetState()                      → { time, duration, paused, playing, ended, error }
//   mpvGetTracks()                     → { audio: [...], subtitle: [...] }
//   mpvSetAudioTrack(id) / mpvSetSubtitleTrack(id)
//   mpvSendBehind(parentNsView)        → reorder mpv subview under Chromium
//   mpvSetSubviewFrame(parent,x,y,w,h)
//   mpvDebugSubviews(parent)
//   mpvGetCapabilities()               → { videoDecoders, audioDecoders, subtitleCodecs, demuxers }
//
// Single global mpv_handle at module scope; this matches Caramba's
// playback model (one active session at a time).

#include <napi.h>
#import <Cocoa/Cocoa.h>
#include <mpv/client.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

static mpv_handle* gMpv = nullptr;

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
    if (gMpv) {
        mpv_terminate_destroy(gMpv);
        gMpv = nullptr;
    }
}

// mpvInit(nsViewBuffer) — must be called once before mpvPlay.
//
// Sets default options matched to embed-in-Electron usage (no OSD, no
// keyboard/mouse input, 5s cache to absorb NAS hiccups), then binds the
// "wid" option to the NSView pointer so mpv's video surface lives
// inside the BrowserWindow's native view tree.
static Napi::Value MpvInit(const Napi::CallbackInfo& info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsBuffer()) {
        Napi::TypeError::New(env, "mpvInit(nsView: Buffer)")
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

    // Power-save / window: leave to the host. Caramba's vlc IPC starts a
    // 'prevent-display-sleep' blocker around playback; mpv shouldn't try
    // to manage that itself. force-window=no because we embed via wid.
    mpv_set_option_string(gMpv, "stop-screensaver", "no");
    mpv_set_option_string(gMpv, "force-window", "no");
    mpv_set_option_string(gMpv, "idle", "no");

    // Track selection is owned by Caramba (UI picks, server pre-selects
    // via select_audio_track / select_subtitle_track). Disable mpv's
    // heuristic so unspecified tracks stay disabled.
    mpv_set_option_string(gMpv, "track-auto-selection", "no");

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
    // for mpv's MPV_FORMAT_INT64 option type.
    int64_t wid = (int64_t)(intptr_t)view;
    int err = mpv_set_option(gMpv, "wid", MPV_FORMAT_INT64, &wid);
    if (err < 0) {
        fprintf(stderr, "[mpv-embed] set wid failed: %s\n", mpv_error_string(err));
    }

    err = mpv_initialize(gMpv);
    if (err < 0) {
        std::string msg = std::string("mpv_initialize failed: ") + mpv_error_string(err);
        releaseMpv();
        Napi::Error::New(env, msg).ThrowAsJavaScriptException();
        return env.Null();
    }

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
    std::string optStr = "start=" + std::to_string(startTime) + ",pause=no";
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

static Napi::Object Init(Napi::Env env, Napi::Object exports) {
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
    exports.Set("mpvGetCapabilities",  Napi::Function::New(env, MpvGetCapabilities));
    return exports;
}

NODE_API_MODULE(mpv_embed, Init)
