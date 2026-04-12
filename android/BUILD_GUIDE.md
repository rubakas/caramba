# Building and Testing Caramba for Android TV

## What Was Built

A complete native Android TV app for Google Chromecast with Google TV devices using:
- **React** (same UI code as web/desktop - 100% code reuse)
- **Capacitor** (framework for wrapping React in native Android)
- **Google Cast Framework** (Chromecast native support)
- **Chromium WebView** (for React rendering)

## Key Differences from Web/Desktop

| Aspect | Web | Desktop | Android TV |
|--------|-----|---------|-----------|
| **Code Base** | React only | React + Electron IPC | React + Capacitor |
| **Storage** | localStorage | SQLite (local) + RPC | SharedPreferences (API URL) |
| **Server Mode** | HTTP API only | Hybrid (Local + HTTP) | HTTP API only |
| **File Management** | None | Browse/Sync folders | None |
| **Video Playback** | hls.js | Local ffmpeg + HLS | Chromium WebView (HLS/fMP4) |
| **Settings UI** | Hidden | Full settings page | API URL config only |
| **Navigation** | Mouse/Touch | Mouse/Keyboard | Remote D-pad only |
| **Installation** | Browser | DMG/Installer | APK sideload |

## Prerequisites for Building

### System Requirements
- **macOS/Linux/Windows** development machine
- **Java JDK 17** or higher
- **Android SDK** API 34+ (install via Android Studio)
- **Android NDK** (optional, for advanced builds)
- **Gradle 8.2+** (usually bundled with Android SDK)

### Get Android SDK

1. Download Android Studio: https://developer.android.com/studio
2. Launch Android Studio
3. Tools → SDK Manager → Select API 34+ → Install
4. Set ANDROID_HOME environment variable:
   ```bash
   export ANDROID_HOME=$HOME/Library/Android/sdk  # macOS
   # OR
   export ANDROID_HOME=$HOME/Android/Sdk  # Linux
   ```

### Node.js Setup
```bash
# Verify Node 18+
node --version

# Install pnpm globally if not already
npm install -g pnpm@latest
```

## Building the APK

### Step 1: Install Capacitor Dependencies

```bash
cd /path/to/caramba/android
pnpm install
```

### Step 2: Build React Web (must be done first)

```bash
cd ../web
pnpm build

# Verify dist/ folder was created with these files:
# - index.html
# - assets/index-*.js
# - assets/index-*.css
```

### Step 3: Sync to Android

```bash
cd ../android
npx cap sync android
```

This copies:
- Web build assets → `android/app/src/main/assets/public/`
- Capacitor config → `android/app/src/main/assets/capacitor.config.json`

### Step 4: Open in Android Studio

```bash
npx cap open android
```

This launches Android Studio with the Android project ready to build.

### Step 5: Build Release APK

**Option A: Via Android Studio UI**
1. Build → Build Bundle(s) / APK(s) → Build APK(s)
2. Wait for build to complete
3. APK location: `android/app/release/app-release-unsigned.apk`

**Option B: Via CLI (Gradle)**
```bash
cd android/android

# Debug APK (for testing)
./gradlew assembleDebug
# Output: app/build/outputs/apk/debug/app-debug.apk

# Release APK (for distribution)
./gradlew assembleRelease
# Output: app/build/outputs/apk/release/app-release-unsigned.apk
```

### Step 6: Sign APK (for Google Play Store)

```bash
# Generate keystore (one-time)
keytool -genkey -v -keystore caramba-release.keystore \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias caramba

# Sign APK
jarsigner -verbose -sigalg SHA1withRSA \
  -digestalg SHA1 \
  -keystore caramba-release.keystore \
  app-release-unsigned.apk caramba

# Zipalign (optimize APK)
zipalign -v 4 app-release-unsigned.apk app-release-signed.apk
```

## Testing on Chromecast

### Option 1: Via Android Emulator

```bash
# Create Android TV emulator in Android Studio
# Device: Chromecast with Google TV (emulator)
# API Level: 34+

# Install APK in emulator
adb install app-release.apk

# Launch app
adb shell am start -n com.caramba.tv/.MainActivity
```

### Option 2: Via Real Chromecast Device

**Prerequisites:**
- Chromecast with Google TV device
- USB-A to USB-C cable (or USB hub)
- Developer mode enabled on Chromecast

**Steps:**
```bash
# Enable USB debugging on Chromecast
# Settings → About → Developer options → USB debugging (ON)

# Connect device via USB
adb devices
# Should show device serial number

# Install APK
adb install app-release.apk

# Grant permissions (if prompted)
adb shell pm grant com.caramba.tv android.permission.INTERNET

# Launch app
adb shell am start -n com.caramba.tv/.MainActivity
```

### First Launch Configuration

1. App will load with "Loading..." screen
2. Detects API URL from Capacitor Preferences storage
3. Falls back to `http://localhost:3001` if not configured
4. Navigate to Settings (Settings in navbar)
5. Enter your Caramba server URL: `http://192.168.1.X:3001`
6. Reload app (or navigate to Library)
7. Verify connection by browsing Series/Movies

### Remote Navigation

- **D-Pad Up/Down**: Scroll, navigate menu items
- **D-Pad Left/Right**: Switch between tabs
- **OK/Center**: Select, submit forms
- **Back**: Go back to previous screen
- **Home**: Return to Android TV home screen

### Testing Playback

1. Navigate to any Series → Episode
2. Click Play button
3. Video should play in WebView with HLS/fMP4 stream
4. Controls should respond to remote
5. Verify:
   - Video starts playing (no codec errors)
   - Audio works
   - Seeking works (fast-forward/rewind)
   - Subtitles load (if available)

## Configuration

### Changing API URL at Runtime

1. Press Settings button on remote
2. Navigate to "Server Configuration"
3. Enter new URL: `http://IP:PORT`
4. URL is saved to device storage (Capacitor Preferences)
5. Reload app to reconnect

### Environment Variables

```bash
# Set API base for web build (not needed for Android)
export VITE_API_BASE="http://localhost:3001"

# Or in .env file
echo "VITE_API_BASE=http://localhost:3001" > .env
```

## Common Issues & Fixes

### "Build failed: SDK not found"
```bash
# Set ANDROID_HOME correctly
export ANDROID_HOME=$HOME/Library/Android/sdk
echo $ANDROID_HOME  # Verify

# Reload in Android Studio: File → Sync Now
```

### "APK installation failed: INSTALL_FAILED_INVALID_APK"
```bash
# Re-sign APK
jarsigner -verify -verbose app-release-unsigned.apk

# Or rebuild
cd android/android && ./gradlew clean assembleDebug
```

### "Device not found (adb)"
```bash
# Restart adb daemon
adb kill-server
adb start-server

# List devices
adb devices

# If still not showing, check:
# - USB cable connection
# - USB debugging enabled on device
# - drivers installed (Windows)
```

### "Video won't play: codec error"
- Verify server supports HLS streaming (`/up/streams/*`)
- Check network connectivity: `adb shell ping 8.8.8.8`
- Enable debug logs: `adb logcat | grep -i media`

### "Remote navigation not working"
- Ensure app window has focus (click on screen)
- Test in Settings page first (simpler interface)
- Check WebView focus: press Back, then navigate back to app

### "API URL not persisting"
- Verify Capacitor Preferences plugin loaded: `adb logcat | grep Capacitor`
- Check localStorage fallback: Open browser DevTools in app (if available)
- Clear app data and reconfigure: `adb shell pm clear com.caramba.tv`

## Distribution

### For Sideload (Direct APK)
1. Build release APK (follow steps above)
2. Sign APK (recommended for security)
3. Share `.apk` file (size ~100-120MB)
4. Users install via: `adb install caramba-app-release.apk`

### For Google Play Store (Future)
1. Sign up as Google Play developer ($25 one-time fee)
2. Prepare store listing (screenshots, description)
3. Upload signed APK to Play Console
4. Set up pricing/distribution
5. Submit for review (~1-3 days)
6. Users install from Play Store app

## Performance Optimization

### APK Size (~100-120MB)
- Chromium WebView: ~80MB
- Capacitor + plugins: ~10MB
- React + assets: ~15-20MB
- Google Cast SDK: ~5-10MB

### Reduce Size (Advanced)
```gradle
// In android/app/build.gradle
android {
  packagingOptions {
    exclude 'META-INF/proguard/androidx-*.pro'
  }
}
```

### Network Optimization
- Use local API server on same network (lower latency)
- Enable gzip compression on server
- Cache series/movies metadata locally (future feature)

## Next Steps

1. **Testing**: Install APK and verify playback works
2. **Crash Debugging**: `adb logcat` to see logs
3. **Performance**: Monitor memory usage: `adb shell dumpsys meminfo`
4. **Publication**: Prepare for Google Play Store (signing, versioning)
5. **Enhancement**: Add Leanback UI for better TV experience

## Useful Commands

```bash
# View device logs
adb logcat

# Install APK with output
adb install -r app-release.apk

# Uninstall app
adb uninstall com.caramba.tv

# Restart app
adb shell am force-stop com.caramba.tv
adb shell am start -n com.caramba.tv/.MainActivity

# Clear app data
adb shell pm clear com.caramba.tv

# Check app permissions
adb shell pm list permissions -g com.caramba.tv

# Get device info
adb shell getprop ro.build.version.release  # Android version
adb shell getprop ro.product.model  # Device model
```

## Useful Links

- [Capacitor Android Docs](https://capacitorjs.com/docs/android)
- [Android Studio Setup](https://developer.android.com/studio/install)
- [Android TV Development](https://developer.android.com/training/tv)
- [Google Cast Framework](https://developers.google.com/cast/docs/android_sender)
- [ADB Reference](https://developer.android.com/tools/adb)

---

## Summary

You now have a complete Android TV app ready for building! The app:
✅ Reuses 100% of React code (no rewrites)
✅ Supports configurable API URLs (like desktop)
✅ Optimized for TV viewing (1920x1080+, D-pad navigation)
✅ Integrates Google Cast Framework (native Chromecast support)
✅ Ready to sideload on Chromecast devices

Next: Build the APK and test on your Chromecast device!
