# Caramba Android TV App

Native Android TV app for Google Chromecast with Google TV devices. Powered by Capacitor and React.

## Features

- 🎬 Stream movies and TV shows to your Chromecast
- ⚡ Same React UI as web/desktop versions
- 🎮 Full D-pad remote navigation support
- 🔌 Configurable API server URL (local or remote)
- 📺 Optimized for 1920x1080+ TV viewing distances
- 🌐 HLS and fMP4 video format support

## Building

### Prerequisites

- Node.js 18+
- Java JDK 17+
- Android SDK (API 34+)
- Android NDK (for native compilation)
- Gradle 8.2+

### Build Steps

1. **Install dependencies**
   ```bash
   cd android
   pnpm install
   ```

2. **Build web first**
   ```bash
   cd ../web
   pnpm build
   ```

3. **Sync to Android**
   ```bash
   cd ../android
   npx cap sync android
   ```

4. **Open in Android Studio**
   ```bash
   npx cap open android
   ```

5. **Build APK**
   - In Android Studio: Build → Build Bundle(s) / APK(s) → Build APK(s)
   - Or via CLI:
   ```bash
   npx cap build android --release
   ```

## Installation on Chromecast

### Via APK File

1. Download APK to Chromecast device (via USB or ADB)
2. Install:
   ```bash
   adb install app-release.apk
   ```
3. Grant permissions when prompted
4. Launch app from Chromecast home screen

### Via Google Play Store (if published)

1. Open Google Play Store on Chromecast
2. Search for "Caramba"
3. Install

## Configuration

### Server URL

On first launch, set your Caramba server URL in Settings:

- **Local network**: `http://192.168.1.100:3001` (replace IP)
- **Hostname**: `http://caramba.local:3001`
- **Remote**: `https://caramba.example.com:3001`

## Architecture

```
Caramba Android TV (Capacitor WebView)
├── React UI (100% shared with web)
├── Capacitor Plugins
│   ├── Preferences (API URL storage)
│   ├── App (lifecycle)
│   └── Google Cast Framework
└── Native Android (Kotlin)
    ├── CastOptionsProvider
    ├── Chrome Media Router
    └── D-pad navigation handler
```

## Files

- `capacitor.config.ts` - Main Capacitor configuration
- `android/app/src/main/java/com/caramba/tv/` - Native Android code
- `android/app/build.gradle` - Android build configuration

## Troubleshooting

### APK won't install
- Ensure minSdkVersion (21) is supported on device
- Check sufficient storage available
- Grant necessary permissions

### Video playback fails
- Verify server URL is correct and reachable
- Check network connectivity on TV
- Ensure server supports HLS streaming

### Remote navigation not working
- Verify D-pad events are being captured
- Check WebView focus (press back/home then return to app)
- Test in Settings page first (simpler UI)

## Development

### Hot reload

For development, use the web dev server:

```bash
cd web
pnpm dev
# Modify capacitor.config.ts server.url to point to dev machine
```

### Native debugging

```bash
# Connect device via ADB
adb logcat | grep caramba
```

### Capacity testing

Test on various network conditions:

```bash
# Simulate slow network
adb shell netstat
adb shell pm set-inactive com.caramba.tv false
```

## Performance Notes

- WebView runs Chromium 90+
- Supports hardware-accelerated H.264/HEVC decoding
- Typical app size: ~100-120MB (includes Chromium)
- Minimum 2GB RAM recommended for 1080p playback

## Future Improvements

- [ ] Publish to Google Play Store
- [ ] Offline video caching
- [ ] Multi-instance casting support
- [ ] Picture-in-picture overlay controls
- [ ] Wake-on-LAN for remote servers
- [ ] Android TV Leanback UI (native look)

## License

Same as Caramba desktop app (see root LICENSE file)
