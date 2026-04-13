package com.caramba.tv;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.util.Log;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Capacitor plugin for auto-updating the Android TV app from GitHub Releases.
 * Mirrors the desktop app's update mechanism.
 */
@CapacitorPlugin(name = "CarambaUpdater")
public class CarambaUpdaterPlugin extends Plugin {
    private static final String TAG = "CarambaUpdater";
    private static final String GITHUB_REPO = "rubakas/caramba";
    private static final String API_URL = "https://api.github.com/repos/" + GITHUB_REPO + "/releases/latest";
    
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    
    // Cached update info from checkForUpdate
    private JSObject pendingUpdateInfo = null;
    // Path to downloaded APK
    private File pendingInstallFile = null;
    
    /**
     * Parse version string "1.0.5" into int array [1, 0, 5]
     */
    private int[] parseVersion(String version) {
        if (version == null) return null;
        String cleaned = version.replaceFirst("^v", "");
        String[] parts = cleaned.split("\\.");
        if (parts.length != 3) return null;
        try {
            return new int[] {
                Integer.parseInt(parts[0]),
                Integer.parseInt(parts[1]),
                Integer.parseInt(parts[2])
            };
        } catch (NumberFormatException e) {
            return null;
        }
    }
    
    /**
     * Returns true if version a is newer than version b
     */
    private boolean isNewer(int[] a, int[] b) {
        for (int i = 0; i < 3; i++) {
            if (a[i] > b[i]) return true;
            if (a[i] < b[i]) return false;
        }
        return false;
    }
    
    /**
     * Get current app version from package info
     */
    private String getCurrentVersion() {
        try {
            Context ctx = getContext();
            PackageInfo pInfo = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
            return pInfo.versionName;
        } catch (PackageManager.NameNotFoundException e) {
            return "0.0.0";
        }
    }
    
    /**
     * Fetch JSON from URL following redirects
     */
    private JSONObject fetchJson(String urlString) throws Exception {
        URL url = new URL(urlString);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestProperty("User-Agent", "Caramba/" + getCurrentVersion());
        conn.setInstanceFollowRedirects(true);
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(30000);
        
        int status = conn.getResponseCode();
        if (status != 200) {
            conn.disconnect();
            throw new Exception("HTTP " + status);
        }
        
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line);
            }
        }
        conn.disconnect();
        
        return new JSONObject(sb.toString());
    }
    
    /**
     * Fetch plain text from URL following redirects
     */
    private String fetchText(String urlString) throws Exception {
        URL url = new URL(urlString);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestProperty("User-Agent", "Caramba/" + getCurrentVersion());
        conn.setInstanceFollowRedirects(true);
        conn.setConnectTimeout(10000);
        conn.setReadTimeout(30000);
        
        int status = conn.getResponseCode();
        if (status != 200) {
            conn.disconnect();
            throw new Exception("HTTP " + status);
        }
        
        StringBuilder sb = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append("\n");
            }
        }
        conn.disconnect();
        
        return sb.toString();
    }
    
    @PluginMethod
    public void checkForUpdate(PluginCall call) {
        executor.execute(() -> {
            try {
                JSONObject release = fetchJson(API_URL);
                
                String tagName = release.optString("tag_name", "");
                int[] latestParsed = parseVersion(tagName);
                int[] currentParsed = parseVersion(getCurrentVersion());
                
                if (latestParsed == null || currentParsed == null) {
                    call.resolve(null);
                    return;
                }
                
                if (!isNewer(latestParsed, currentParsed)) {
                    call.resolve(null);
                    return;
                }
                
                // Find APK asset
                JSONArray assets = release.optJSONArray("assets");
                if (assets == null) {
                    call.resolve(null);
                    return;
                }
                
                JSONObject apkAsset = null;
                JSONObject checksumsAsset = null;
                
                for (int i = 0; i < assets.length(); i++) {
                    JSONObject asset = assets.getJSONObject(i);
                    String name = asset.optString("name", "");
                    
                    if (name.endsWith(".apk")) {
                        apkAsset = asset;
                    }
                    if (name.toLowerCase().matches("checksums?\\.txt") || 
                        name.toLowerCase().startsWith("sha256")) {
                        checksumsAsset = asset;
                    }
                }
                
                if (apkAsset == null) {
                    call.resolve(null);
                    return;
                }
                
                String assetUrl = apkAsset.optString("browser_download_url", "");
                String assetName = apkAsset.optString("name", "");
                
                // Try to get SHA256 from checksums file
                String sha256 = null;
                if (checksumsAsset != null) {
                    try {
                        String checksumText = fetchText(checksumsAsset.optString("browser_download_url", ""));
                        for (String line : checksumText.split("\n")) {
                            String[] parts = line.trim().split("\\s+");
                            if (parts.length >= 2 && parts[1].equals(assetName) && 
                                parts[0].matches("[a-fA-F0-9]{64}")) {
                                sha256 = parts[0].toLowerCase();
                                break;
                            }
                        }
                    } catch (Exception e) {
                        Log.w(TAG, "Failed to fetch checksums: " + e.getMessage());
                    }
                }
                
                JSObject result = new JSObject();
                result.put("version", tagName.replaceFirst("^v", ""));
                result.put("assetUrl", assetUrl);
                result.put("assetName", assetName);
                result.put("sha256", sha256);
                
                pendingUpdateInfo = result;
                call.resolve(result);
                
            } catch (Exception e) {
                Log.e(TAG, "checkForUpdate failed", e);
                JSObject error = new JSObject();
                error.put("error", e.getMessage());
                call.resolve(error);
            }
        });
    }
    
    @PluginMethod
    public void downloadUpdate(PluginCall call) {
        executor.execute(() -> {
            try {
                if (pendingUpdateInfo == null) {
                    JSObject error = new JSObject();
                    error.put("ok", false);
                    error.put("error", "No update available");
                    call.resolve(error);
                    return;
                }
                
                String assetUrl = pendingUpdateInfo.getString("assetUrl");
                String assetName = pendingUpdateInfo.getString("assetName");
                String expectedSha256 = pendingUpdateInfo.getString("sha256");
                
                if (assetUrl == null || assetUrl.isEmpty()) {
                    JSObject error = new JSObject();
                    error.put("ok", false);
                    error.put("error", "No download URL");
                    call.resolve(error);
                    return;
                }
                
                // Download to cache directory
                File cacheDir = getContext().getCacheDir();
                File downloadFile = new File(cacheDir, assetName);
                
                URL url = new URL(assetUrl);
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setRequestProperty("User-Agent", "Caramba/" + getCurrentVersion());
                conn.setInstanceFollowRedirects(true);
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(60000);
                
                int status = conn.getResponseCode();
                if (status != 200) {
                    conn.disconnect();
                    JSObject error = new JSObject();
                    error.put("ok", false);
                    error.put("error", "Download failed: HTTP " + status);
                    call.resolve(error);
                    return;
                }
                
                int total = conn.getContentLength();
                int downloaded = 0;
                
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                
                try (InputStream in = new BufferedInputStream(conn.getInputStream());
                     FileOutputStream out = new FileOutputStream(downloadFile)) {
                    
                    byte[] buffer = new byte[8192];
                    int count;
                    
                    while ((count = in.read(buffer)) != -1) {
                        out.write(buffer, 0, count);
                        digest.update(buffer, 0, count);
                        downloaded += count;
                        
                        if (total > 0) {
                            int percent = (int) ((downloaded * 100L) / total);
                            JSObject progress = new JSObject();
                            progress.put("percent", percent);
                            progress.put("downloaded", downloaded);
                            progress.put("total", total);
                            notifyListeners("downloadProgress", progress);
                        }
                    }
                }
                
                conn.disconnect();
                
                // Verify checksum if provided
                if (expectedSha256 != null && !expectedSha256.isEmpty()) {
                    byte[] hashBytes = digest.digest();
                    StringBuilder sb = new StringBuilder();
                    for (byte b : hashBytes) {
                        sb.append(String.format("%02x", b));
                    }
                    String actualHash = sb.toString();
                    
                    if (!actualHash.equals(expectedSha256)) {
                        downloadFile.delete();
                        JSObject error = new JSObject();
                        error.put("ok", false);
                        error.put("error", "Checksum mismatch! Expected " + expectedSha256 + 
                                          ", got " + actualHash);
                        call.resolve(error);
                        return;
                    }
                }
                
                pendingInstallFile = downloadFile;
                
                JSObject result = new JSObject();
                result.put("ok", true);
                call.resolve(result);
                
            } catch (Exception e) {
                Log.e(TAG, "downloadUpdate failed", e);
                JSObject error = new JSObject();
                error.put("ok", false);
                error.put("error", e.getMessage());
                call.resolve(error);
            }
        });
    }
    
    @PluginMethod
    public void installUpdate(PluginCall call) {
        try {
            if (pendingInstallFile == null || !pendingInstallFile.exists()) {
                JSObject error = new JSObject();
                error.put("ok", false);
                error.put("error", "No update downloaded");
                call.resolve(error);
                return;
            }
            
            Context context = getContext();
            Intent intent = new Intent(Intent.ACTION_VIEW);
            
            Uri apkUri;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // Android 7+ requires FileProvider
                apkUri = FileProvider.getUriForFile(
                    context,
                    context.getPackageName() + ".fileprovider",
                    pendingInstallFile
                );
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } else {
                apkUri = Uri.fromFile(pendingInstallFile);
            }
            
            intent.setDataAndType(apkUri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            
            context.startActivity(intent);
            
            JSObject result = new JSObject();
            result.put("ok", true);
            call.resolve(result);
            
        } catch (Exception e) {
            Log.e(TAG, "installUpdate failed", e);
            JSObject error = new JSObject();
            error.put("ok", false);
            error.put("error", e.getMessage());
            call.resolve(error);
        }
    }
}
