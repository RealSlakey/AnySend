// Shizuku UserService interface for the screen-mirror hotspot bootstrap.
// Runs in the shell-UID (2000) service process started by Shizuku, which is
// the only path verified to raise the Wi-Fi hotspot on Android 14.
package com.slakey.anysend;

interface IMirrorShizukuService {
    boolean startHotspot() = 1;
    boolean stopHotspot() = 2;

    // Hotspot AP config (SSID / WPA key) read via WifiManager reflection in
    // the shell-UID process; empty strings when unavailable.
    String getHotspotSsid() = 3;
    String getHotspotPassword() = 4;

    // Screen-mirror bridge: write the scrcpy-server jar to /data/local/tmp and
    // spawn it as shell UID 2000 (forward tunnel mode), then pump the server's
    // abstract sockets to loopback TCP ports so the LAN peer can connect
    // directly without adb. Returns a JSON string
    // {"videoPort":N,"controlPort":N,"scid":"xxxxxxxx"} or "" on failure.
    String startMirrorBridge(in byte[] jar, in String argsJson) = 5;
    void stopMirrorBridge() = 6;
}
