package tsnetbridge;

/**
 * Stub implementation of the Tailscale tsnet bridge (gomobile-generated AAR).
 *
 * This stub is ONLY compiled when the real `tsnetbridge.aar` is NOT present
 * in android/app/libs/. It allows the project to build and run in
 * "Direct LAN Mode" without the Tailscale native library.
 *
 * Method signatures MUST match the gomobile-generated AAR exactly
 * (see tsnetbridge.Tsnetbridge in the real AAR).
 */
public class Tsnetbridge {

    public static long start(String authKey, String stateDir, String hostname) {
        return -1L;
    }

    public static boolean isStarted() {
        return false;
    }

    public static String getSelfInfo() {
        return "";
    }

    public static String getPeers() {
        return "[]";
    }

    public static String dial(String network, String addr) {
        return "{\"error\":\"tailscale not available\"}";
    }

    public static String listen(String network, String addr) {
        return "{\"error\":\"tailscale not available\"}";
    }

    public static String accept(long listenerHandle) {
        return "{\"error\":\"tailscale not available\"}";
    }

    public static byte[] read(long handle, long maxLen) throws Exception {
        return new byte[0];
    }

    public static long write(long handle, byte[] data) throws Exception {
        return -1L;
    }

    public static long closeConn(long handle) {
        return 0L;
    }

    public static long closeListener(long handle) {
        return 0L;
    }

    public static long close() {
        return 0L;
    }

    public static void freeString(String s) {
        // no-op
    }
}
