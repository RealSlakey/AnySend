/*
 * napi_bridge.cpp - HarmonyOS NAPI bridge that exposes the tsnetbridge
 * Go shared library functions to ArkTS.
 *
 * The Go c-shared library (libtsnetbridge.so) is resolved at runtime with
 * dlopen rather than being declared as DT_NEEDED. Go's c-shared output uses the
 * initial-exec TLS model, which is only legal for libraries loaded at process
 * start. OpenHarmony loads NAPI modules with dlopen and its musl linker rejects
 * it ("initial-exec TLS resolves to dynamic definition"), so a hard link would
 * make libtsnapi.so itself fail to load - which throws in ArkTS and kills the
 * app on launch. Loading lazily keeps the app alive: when the Go library cannot
 * be loaded, every entry point returns a failure sentinel and callers fall back
 * to Direct LAN Mode.
 */
#include "napi/native_api.h"
#include "AbilityKit/native_child_process.h"
#include <hilog/log.h>

#include <dlfcn.h>
#include <pthread.h>
#include <string>
#include <cstring>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <unistd.h>

/* hilog/log.h already defines LOG_TAG/LOG_DOMAIN, so use distinct names. */
#define TSNAPI_LOG_TAG "tsnapi"
#define TSNAPI_LOG_DOMAIN 0xD003300

/* Signatures exported by the Go c-shared build (see cpp/tsnetbridge.h). */
typedef int32_t (*FnStart)(const char*, const char*, const char*);
typedef int32_t (*FnStartAsync)(const char*, const char*, const char*);
typedef char*   (*FnStartState)(void);
typedef char*   (*FnLastError)(void);
typedef char*   (*FnGetSelfInfo)(void);
typedef char*   (*FnGetPeers)(void);
typedef char*   (*FnDial)(const char*, const char*);
typedef char*   (*FnListen)(const char*, const char*);
typedef char*   (*FnAccept)(int64_t);
typedef int32_t (*FnAcceptStart)(int64_t);
typedef char*   (*FnAcceptPoll)(int64_t);
typedef char*   (*FnForwardTCP)(int32_t, const char*);
typedef int32_t (*FnCloseForward)(int64_t);
typedef char*   (*FnRead)(int64_t, int32_t);
typedef int32_t (*FnWrite)(int64_t, const char*, int32_t);
typedef int32_t (*FnCloseConn)(int64_t);
typedef int32_t (*FnCloseListener)(int64_t);
typedef int32_t (*FnClose)(void);
typedef int32_t (*FnIsStarted)(void);
typedef void    (*FnFreeString)(char*);

/* ---------- runtime-resolved Go library ---------- */

struct GoApi {
    bool tried;
    bool ok;
    void* handle;
    FnStart Start;
    FnStartAsync StartAsync;
    FnStartState StartState;
    FnLastError LastError;
    FnGetSelfInfo GetSelfInfo;
    FnGetPeers GetPeers;
    FnDial Dial;
    FnListen Listen;
    FnAccept Accept;
    FnAcceptStart AcceptStart;
    FnAcceptPoll AcceptPoll;
    FnForwardTCP ForwardTCP;
    FnCloseForward CloseForward;
    FnRead Read;
    FnWrite Write;
    FnCloseConn CloseConn;
    FnCloseListener CloseListener;
    FnClose Close;
    FnIsStarted IsStarted;
    FnFreeString FreeString;
};

static GoApi g_go = {};

static void ensureGoLoaded() {
    if (g_go.tried) {
        return;
    }

    void* h = dlopen("libtsnetbridge.so", RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        const char* err = dlerror();
        OH_LOG_Print(LOG_APP, LOG_ERROR, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                     "dlopen(libtsnetbridge.so) failed, Tailscale unavailable: %{public}s",
                     err ? err : "unknown");
        g_go.tried = true;
        return;
    }

    GoApi api = {};
    api.handle = h;
    api.Start = (FnStart)dlsym(h, "Start");
    // Optional: only newer Go builds export the async pair and LastError.
    api.StartAsync = (FnStartAsync)dlsym(h, "StartAsync");
    api.StartState = (FnStartState)dlsym(h, "StartState");
    api.LastError = (FnLastError)dlsym(h, "LastError");
    api.GetSelfInfo = (FnGetSelfInfo)dlsym(h, "GetSelfInfo");
    api.GetPeers = (FnGetPeers)dlsym(h, "GetPeers");
    api.Dial = (FnDial)dlsym(h, "Dial");
    api.Listen = (FnListen)dlsym(h, "Listen");
    api.Accept = (FnAccept)dlsym(h, "Accept");
    // Optional: async accept pair for the worker-thread data plane.
    api.AcceptStart = (FnAcceptStart)dlsym(h, "AcceptStart");
    api.AcceptPoll = (FnAcceptPoll)dlsym(h, "AcceptPoll");
    api.ForwardTCP = (FnForwardTCP)dlsym(h, "ForwardTCP");
    api.CloseForward = (FnCloseForward)dlsym(h, "CloseForward");
    api.Read = (FnRead)dlsym(h, "Read");
    api.Write = (FnWrite)dlsym(h, "Write");
    api.CloseConn = (FnCloseConn)dlsym(h, "CloseConn");
    api.CloseListener = (FnCloseListener)dlsym(h, "CloseListener");
    api.Close = (FnClose)dlsym(h, "Close");
    api.IsStarted = (FnIsStarted)dlsym(h, "IsStarted");
    api.FreeString = (FnFreeString)dlsym(h, "FreeString");

    if (api.Start == nullptr || api.GetSelfInfo == nullptr || api.GetPeers == nullptr ||
        api.Dial == nullptr || api.Listen == nullptr || api.Accept == nullptr ||
        api.Read == nullptr || api.Write == nullptr || api.CloseConn == nullptr ||
        api.CloseListener == nullptr || api.Close == nullptr || api.IsStarted == nullptr ||
        api.FreeString == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                     "libtsnetbridge.so loaded but missing entry points, Tailscale unavailable");
        dlclose(h);
        g_go.tried = true;
        return;
    }

    api.tried = true;
    api.ok = true;
    g_go = api;
    OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                 "libtsnetbridge.so loaded, Tailscale available");
}

/* ---------- helpers ---------- */

static char* dupStr(const char* s) {
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

/* Frees a string from the Go library, or one of our own fallbacks. */
static void releaseString(char* s) {
    if (s == nullptr) {
        return;
    }
    if (g_go.ok) {
        g_go.FreeString(s);
    } else {
        free(s);
    }
}

static std::string getStringArg(napi_env env, napi_value arg) {
    size_t len = 0;
    napi_get_value_string_utf8(env, arg, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, arg, &s[0], len + 1, &len);
    return s;
}

static napi_value makeString(napi_env env, const char* s) {
    napi_value result;
    napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value makeInt32(napi_env env, int32_t v) {
    napi_value result;
    napi_create_int32(env, v, &result);
    return result;
}

static int64_t getInt64Arg(napi_env env, napi_value arg) {
    int64_t v = 0;
    napi_get_value_int64(env, arg, &v);
    return v;
}

static int32_t getInt32Arg(napi_env env, napi_value arg) {
    int32_t v = 0;
    napi_get_value_int32(env, arg, &v);
    return v;
}

/* ---------- exposed methods ---------- */

/* JsStartAsync launches Start on a Go background goroutine and returns
 * immediately. Synchronous Start must not be called from the UI thread:
 * tsnet's full start can exceed HarmonyOS's 6 s main-thread watchdog
 * (THREAD_BLOCK_6S kills the process). The caller polls startState(). */
static napi_value JsStartAsync(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.StartAsync == nullptr) {
        return makeInt32(env, -1);
    }
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string authKey = getStringArg(env, args[0]);
    std::string stateDir = getStringArg(env, args[1]);
    std::string hostname = getStringArg(env, args[2]);
    int32_t rc = g_go.StartAsync(authKey.c_str(), stateDir.c_str(), hostname.c_str());
    OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                 "StartAsync dispatched rc=%{public}d", rc);
    return makeInt32(env, rc);
}

static napi_value JsStartState(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.StartState == nullptr) {
        return makeString(env, "");
    }
    char* s = g_go.StartState();
    napi_value result = makeString(env, s ? s : "");
    releaseString(s);
    return result;
}

static napi_value JsStart(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, -1);
    }
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string authKey = getStringArg(env, args[0]);
    std::string stateDir = getStringArg(env, args[1]);
    std::string hostname = getStringArg(env, args[2]);
    int32_t rc = g_go.Start(authKey.c_str(), stateDir.c_str(), hostname.c_str());
    if (rc != 0) {
        const char* goErr = (g_go.LastError != nullptr) ? g_go.LastError() : nullptr;
        OH_LOG_Print(LOG_APP, LOG_ERROR, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                     "Start failed rc=%{public}d hostname=%{public}s err=%{public}s",
                     rc, hostname.c_str(), goErr ? goErr : "");
        if (goErr != nullptr) {
            releaseString(const_cast<char*>(goErr));
        }
    } else {
        OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG, "Start ok");
    }
    return makeInt32(env, rc);
}

static napi_value JsLastError(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.LastError == nullptr) {
        return makeString(env, "");
    }
    char* s = g_go.LastError();
    napi_value result = makeString(env, s ? s : "");
    releaseString(s);
    return result;
}

static napi_value JsGetSelfInfo(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "");
    }
    char* s = g_go.GetSelfInfo();
    napi_value result = makeString(env, s ? s : "");
    releaseString(s);
    return result;
}

static napi_value JsGetPeers(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "[]");
    }
    char* s = g_go.GetPeers();
    napi_value result = makeString(env, s ? s : "[]");
    releaseString(s);
    return result;
}

static napi_value JsDial(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "{\"error\":\"tailscale not available\"}");
    }
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string network = getStringArg(env, args[0]);
    std::string addr = getStringArg(env, args[1]);
    char* s = g_go.Dial(network.c_str(), addr.c_str());
    napi_value result = makeString(env, s ? s : "{}");
    releaseString(s);
    return result;
}

static napi_value JsListen(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "{\"error\":\"tailscale not available\"}");
    }
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string network = getStringArg(env, args[0]);
    std::string addr = getStringArg(env, args[1]);
    char* s = g_go.Listen(network.c_str(), addr.c_str());
    napi_value result = makeString(env, s ? s : "{}");
    releaseString(s);
    return result;
}

/* JsForwardTCP exposes a Tailscale endpoint on 127.0.0.1 so the host's native
 * sockets (scrcpy video/control) can reach it without a kernel TUN device. */
static napi_value JsForwardTCP(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.ForwardTCP == nullptr) {
        return makeString(env, "{\"error\":\"forward not available\"}");
    }
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t localPort = getInt32Arg(env, args[0]);
    std::string target = getStringArg(env, args[1]);
    char* s = g_go.ForwardTCP(localPort, target.c_str());
    napi_value result = makeString(env, s ? s : "{}");
    releaseString(s);
    return result;
}

static napi_value JsCloseForward(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.CloseForward == nullptr) {
        return makeInt32(env, -1);
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    return makeInt32(env, g_go.CloseForward(getInt64Arg(env, args[0])));
}

static napi_value JsAccept(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "{\"error\":\"tailscale not available\"}");
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    char* s = g_go.Accept(handle);
    napi_value result = makeString(env, s ? s : "{}");
    releaseString(s);
    return result;
}

/* JsAcceptStart launches a background Accept on the Go side and returns
 * immediately; the host polls acceptPoll(). A blocking accept() on the UI
 * thread (or even on the worker, which serializes all native commands) would
 * stall everything past HarmonyOS's 6 s watchdog. */
static napi_value JsAcceptStart(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.AcceptStart == nullptr) {
        return makeInt32(env, -1);
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    return makeInt32(env, g_go.AcceptStart(handle));
}

static napi_value JsAcceptPoll(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok || g_go.AcceptPoll == nullptr) {
        return makeString(env, "{\"error\":\"acceptPoll not available\"}");
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    char* s = g_go.AcceptPoll(handle);
    napi_value result = makeString(env, s ? s : "{\"handle\":0}");
    releaseString(s);
    return result;
}

static napi_value JsRead(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeString(env, "{\"data\":\"\",\"err\":\"tailscale not available\"}");
    }
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    int32_t maxLen = getInt32Arg(env, args[1]);
    char* s = g_go.Read(handle, maxLen);
    napi_value result = makeString(env, s ? s : "{}");
    releaseString(s);
    return result;
}

static napi_value JsWrite(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, -1);
    }
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    // args[1] is ArrayBuffer of data
    bool isArrayBuffer = false;
    napi_is_arraybuffer(env, args[1], &isArrayBuffer);
    int32_t written = -1;
    if (isArrayBuffer) {
        void* data = nullptr;
        size_t byteLength = 0;
        napi_get_arraybuffer_info(env, args[1], &data, &byteLength);
        written = g_go.Write(handle, static_cast<const char*>(data), static_cast<int32_t>(byteLength));
    }
    return makeInt32(env, written);
}

static napi_value JsCloseConn(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, 0);
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    return makeInt32(env, g_go.CloseConn(handle));
}

static napi_value JsCloseListener(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, 0);
    }
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    return makeInt32(env, g_go.CloseListener(handle));
}

static napi_value JsClose(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, 0);
    }
    return makeInt32(env, g_go.Close());
}

static napi_value JsIsStarted(napi_env env, napi_callback_info info) {
    ensureGoLoaded();
    if (!g_go.ok) {
        return makeInt32(env, 0);
    }
    return makeInt32(env, g_go.IsStarted());
}

/* ---------- child process diagnostic ---------- */

/*
 * Runs the tsnet probe in a native child process and returns what it reported.
 *
 * The Go c-shared library cannot be dlopen'd in the app process (musl rejects
 * its initial-exec TLS relocation). A freshly spawned native child process has
 * an untouched static TLS area, so it may succeed there - and if it does,
 * embedding Tailscale becomes possible by moving all tsnet work into a child
 * process. Collapses to a copy/paste-free, one-shot experiment: the child
 * writes its report to the path in args[0] and we read it back.
 */
static napi_value JsProbeChild(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string outPath = argc > 0 ? getStringArg(env, args[0]) : std::string();

    /* Resolve a sibling of this library so the child does not need to guess
     * where the HAP unpacked libtsnetbridge.so. */
    std::string bridgePath;
    Dl_info dlInfo = {};
    if (dladdr(reinterpret_cast<void*>(&JsProbeChild), &dlInfo) != 0 && dlInfo.dli_fname != nullptr) {
        std::string self = dlInfo.dli_fname;
        size_t slash = self.rfind('/');
        if (slash != std::string::npos) {
            bridgePath = self.substr(0, slash + 1) + "libtsnetbridge.so";
        }
    }

    std::string entryParams = outPath + "|" + bridgePath;
    NativeChildProcess_Args childArgs = {};
    childArgs.entryParams = const_cast<char*>(entryParams.c_str());
    childArgs.fdList.head = nullptr;
    NativeChildProcess_Options options = {};
    options.isolationMode = NCP_ISOLATION_MODE_NORMAL;
    options.reserved = 0;

    int32_t pid = -1;
    int rc = OH_Ability_StartNativeChildProcess("libtsnetprobe.so:Main", childArgs, options, &pid);
    OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                 "child probe rc=%{public}d pid=%{public}d bridge=%{public}s", rc, pid, bridgePath.c_str());

    usleep(1500000);

    std::string content;
    if (!outPath.empty()) {
        FILE* f = fopen(outPath.c_str(), "r");
        if (f != nullptr) {
            char buf[2048];
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            buf[n] = '\0';
            content = buf;
            fclose(f);
        } else {
            content = "(child probe wrote no report file)";
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                 "child probe report: %{public}s", content.c_str());
    return makeString(env, content.c_str());
}

/* ---------- TLS model control experiment ---------- */

/* Directory this library was loaded from, so siblings can be dlopen'd. */
static std::string selfLibDir() {
    Dl_info dlInfo = {};
    if (dladdr(reinterpret_cast<void*>(&selfLibDir), &dlInfo) != 0 && dlInfo.dli_fname != nullptr) {
        std::string self = dlInfo.dli_fname;
        size_t slash = self.rfind('/');
        if (slash != std::string::npos) {
            return self.substr(0, slash + 1);
        }
    }
    return std::string();
}

static void tryDlopen(const std::string& dir, const char* name, std::string& out) {
    std::string path = dir + name;
    void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h != nullptr) {
        out += std::string("dlopen ") + name + " OK\n";
        OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                     "dlopen %{public}s OK", name);
        return;
    }
    const char* err = dlerror();
    out += std::string("dlopen ") + name + " FAILED: " + (err != nullptr ? err : "(no dlerror)") + "\n";
    OH_LOG_Print(LOG_APP, LOG_ERROR, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG,
                 "dlopen %{public}s FAILED: %{public}s", name, err != nullptr ? err : "(no dlerror)");
}

/*
 * dlopens a 4-byte initial-exec TLS library and then the Go library, in the
 * app process, reporting both outcomes. The small library isolates the TLS
 * model from everything else about the Go runtime.
 */
static napi_value JsProbeTls(napi_env env, napi_callback_info info) {
    std::string dir = selfLibDir();
    std::string out;
    if (dir.empty()) {
        return makeString(env, "self lib dir not resolvable\n");
    }
    out += "lib dir: " + dir + "\n";
    tryDlopen(dir, "libtlsprobe.so", out);
    tryDlopen(dir, "libtsnetbridge.so", out);
    return makeString(env, out.c_str());
}

/* ---------- Go g-slot discovery ---------- */

/*
 * Go's runtime keeps the current goroutine pointer in a per-thread cell that it
 * reaches as "thread pointer + runtime.tls_g". On Android, iOS and Windows that
 * cell is an ordinary pthread key value and its offset from the thread pointer
 * is discovered at run time (see Go's runtime/cgo/gcc_android.c, inittls),
 * because those platforms cannot use ELF TLS in a dlopen'd library. OpenHarmony
 * musl refuses ELF TLS in dlopen'd modules too, so the same trick is how a
 * dlopen'd Go library can work here: take a pthread key, write a magic word
 * through it, then scan around the thread pointer for that word. The offset it
 * lands at is a fixed field of the thread control block - the same on every
 * thread - and the cell is owned by our key alone.
 */
#define GSLOT_MAGIC 0x5a5a5a5a5a5a5a5aULL

static uintptr_t readThreadPointer() {
    uintptr_t tp = 0;
    __asm__ __volatile__("mrs %0, tpidr_el0" : "=r"(tp));
    return tp;
}

static std::string hexStr(uintptr_t v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "0x%lx", (unsigned long)v);
    return buf;
}

/* Mapped ranges from /proc/self/maps, so the scan never faults. */
struct MappedRanges {
    uintptr_t lo[64];
    uintptr_t hi[64];
    int count;
};

static void loadMappedRanges(MappedRanges& m) {
    m.count = 0;
    FILE* f = fopen("/proc/self/maps", "r");
    if (f == nullptr) {
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), f) != nullptr && m.count < 64) {
        unsigned long lo = 0;
        unsigned long hi = 0;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2) {
            continue;
        }
        m.lo[m.count] = (uintptr_t)lo;
        m.hi[m.count] = (uintptr_t)hi;
        m.count++;
    }
    fclose(f);
}

static bool isMapped(const MappedRanges& m, uintptr_t p) {
    for (int i = 0; i < m.count; i++) {
        if (p >= m.lo[i] && p + 8 <= m.hi[i]) {
            return true;
        }
    }
    return false;
}

/*
 * Finds the offset of our key's cell relative to the thread pointer. Returns
 * true and writes the offset on success.
 */
static bool findSlotOffset(uintptr_t tp, int64_t& offset, std::string& out) {
    MappedRanges m;
    loadMappedRanges(m);
    out += "maps entries=" + std::to_string(m.count) + "\n";

    /* Without maps we must stay inside the thread control block, which is
     * adjacent to the thread pointer; a page either side is safely mapped. */
    const int64_t limit = m.count > 0 ? 8192 : 2048;
    const bool guard = m.count > 0;

    for (int64_t off = -limit; off <= limit; off += 8) {
        if (off == 0) {
            continue;
        }
        uintptr_t p = (uintptr_t)((int64_t)tp + off);
        if (guard && !isMapped(m, p)) {
            continue;
        }
        if (*(volatile uint64_t*)p == GSLOT_MAGIC) {
            offset = off;
            out += "magic found at tp" + std::string(off < 0 ? "-" : "+") +
                   std::to_string(off < 0 ? -off : off) + "\n";
            return true;
        }
    }
    out += "magic NOT found within +/-" + std::to_string(limit) + "\n";
    return false;
}

struct SlotReport {
    pthread_key_t key;
    std::string text;
};

static void* slotThreadMain(void* arg) {
    SlotReport* r = (SlotReport*)arg;
    if (pthread_setspecific(r->key, (void*)GSLOT_MAGIC) != 0) {
        r->text += "child thread setspecific failed\n";
        return nullptr;
    }
    uintptr_t tp = readThreadPointer();
    int64_t off = 0;
    r->text += "child thread tp=" + hexStr(tp) + "\n";
    if (findSlotOffset(tp, off, r->text)) {
        r->text += "child thread slot offset=" + std::to_string(off) + "\n";
    }
    return nullptr;
}

/*
 * Reports the offset a dlopen'd Go library would use for its g pointer on this
 * platform, and whether it is stable across threads.
 */
static napi_value JsProbeKeySlot(napi_env env, napi_callback_info info) {
    std::string out = "g-slot discovery\n";

    pthread_key_t key = 0;
    int rc = pthread_key_create(&key, nullptr);
    out += "pthread_key_create rc=" + std::to_string(rc) + " key=" + std::to_string((int)key) + "\n";
    if (rc != 0) {
        return makeString(env, out.c_str());
    }
    pthread_setspecific(key, (void*)GSLOT_MAGIC);

    uintptr_t tp = readThreadPointer();
    out += "main thread tp=" + hexStr(tp) + ", pid=" + std::to_string(getpid()) + "\n";
    int64_t offset = 0;
    bool found = findSlotOffset(tp, offset, out);
    out += std::string("getspecific ") +
           (pthread_getspecific(key) == (void*)GSLOT_MAGIC ? "returns magic" : "MISMATCH") + "\n";

    SlotReport child = {};
    child.key = key;
    pthread_t t = 0;
    if (pthread_create(&t, nullptr, slotThreadMain, &child) == 0) {
        pthread_join(t, nullptr);
        out += child.text;
    } else {
        out += "child thread create failed\n";
    }

    if (found) {
        out += "RESULT: runtime.tls_g must be " + std::to_string(offset) + "\n";
    } else {
        out += "RESULT: no usable g slot found by scanning\n";
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, TSNAPI_LOG_DOMAIN, TSNAPI_LOG_TAG, "gslot %{public}s", out.c_str());
    return makeString(env, out.c_str());
}

/* ---------- module registration ---------- */

// video_decoder.cpp: surface-mode H.264 decoder for the scrcpy mirror page.
void VdRegister(napi_env env, napi_value exports);

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, JsStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAsync", nullptr, JsStartAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startState", nullptr, JsStartState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, JsLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSelfInfo", nullptr, JsGetSelfInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPeers", nullptr, JsGetPeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dial", nullptr, JsDial, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"listen", nullptr, JsListen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"accept", nullptr, JsAccept, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptStart", nullptr, JsAcceptStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"acceptPoll", nullptr, JsAcceptPoll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forwardTcp", nullptr, JsForwardTCP, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeForward", nullptr, JsCloseForward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, JsRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"write", nullptr, JsWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeConn", nullptr, JsCloseConn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeListener", nullptr, JsCloseListener, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, JsClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isStarted", nullptr, JsIsStarted, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeChild", nullptr, JsProbeChild, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeTls", nullptr, JsProbeTls, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeKeySlot", nullptr, JsProbeKeySlot, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    VdRegister(env, exports);
    return exports;
}
EXTERN_C_END

static napi_module tsnapiModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "tsnapi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void Register_tsnapi(void) {
    napi_module_register(&tsnapiModule);
}
