/*
 * napi_bridge.cpp - HarmonyOS NAPI bridge that exposes the tsnetbridge
 * Go shared library functions to ArkTS.
 *
 * Build: linked against libtsnetbridge.so (Go c-shared output) and the
 * OpenHarmony NAPI headers. Produces libtsnapi.so loaded by ArkTS via
 *   import tsnapi from 'libtsnapi.so';
 */
#include "napi/native_api.h"
#include "tsnetbridge.h"

#include <string>
#include <cstring>
#include <cstdlib>

#ifdef TSNETBRIDGE_STUB
/*
 * Stub implementations of the Go tsnetbridge C functions.
 * Used when libtsnetbridge.so is not available during build.
 * Every function returns a failure sentinel so ArkTS callers can
 * detect that Tailscale is unavailable and fall back to Direct LAN Mode.
 */
static char* dupStr(const char* s) {
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

extern "C" {
int32_t Start(const char*, const char*, const char*) { return -1; }
char* GetSelfInfo(void) { return dupStr(""); }
char* GetPeers(void) { return dupStr("[]"); }
char* Dial(const char*, const char*) { return dupStr("{\"error\":\"tailscale not available\"}"); }
char* Listen(const char*, const char*) { return dupStr("{\"error\":\"tailscale not available\"}"); }
char* Accept(int64_t) { return dupStr("{\"error\":\"tailscale not available\"}"); }
char* Read(int64_t, int32_t) { return dupStr("{\"data\":\"\",\"err\":\"tailscale not available\"}"); }
int32_t Write(int64_t, const char*, int32_t) { return -1; }
int32_t CloseConn(int64_t) { return 0; }
int32_t CloseListener(int64_t) { return 0; }
int32_t Close(void) { return 0; }
int32_t IsStarted(void) { return 0; }
void FreeString(char* s) { free(s); }
}
#endif /* TSNETBRIDGE_STUB */

/* ---------- helpers ---------- */

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

static napi_value JsStart(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string authKey = getStringArg(env, args[0]);
    std::string stateDir = getStringArg(env, args[1]);
    std::string hostname = getStringArg(env, args[2]);
    int32_t rc = Start(authKey.c_str(), stateDir.c_str(), hostname.c_str());
    return makeInt32(env, rc);
}

static napi_value JsGetSelfInfo(napi_env env, napi_callback_info info) {
    char* s = GetSelfInfo();
    napi_value result = makeString(env, s ? s : "");
    if (s) FreeString(s);
    return result;
}

static napi_value JsGetPeers(napi_env env, napi_callback_info info) {
    char* s = GetPeers();
    napi_value result = makeString(env, s ? s : "[]");
    if (s) FreeString(s);
    return result;
}

static napi_value JsDial(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string network = getStringArg(env, args[0]);
    std::string addr = getStringArg(env, args[1]);
    char* s = Dial(network.c_str(), addr.c_str());
    napi_value result = makeString(env, s ? s : "{}");
    if (s) FreeString(s);
    return result;
}

static napi_value JsListen(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string network = getStringArg(env, args[0]);
    std::string addr = getStringArg(env, args[1]);
    char* s = Listen(network.c_str(), addr.c_str());
    napi_value result = makeString(env, s ? s : "{}");
    if (s) FreeString(s);
    return result;
}

static napi_value JsAccept(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    char* s = Accept(handle);
    napi_value result = makeString(env, s ? s : "{}");
    if (s) FreeString(s);
    return result;
}

static napi_value JsRead(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    int32_t maxLen = getInt32Arg(env, args[1]);
    char* s = Read(handle, maxLen);
    napi_value result = makeString(env, s ? s : "{}");
    if (s) FreeString(s);
    return result;
}

static napi_value JsWrite(napi_env env, napi_callback_info info) {
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
        written = Write(handle, static_cast<const char*>(data), static_cast<int32_t>(byteLength));
    }
    return makeInt32(env, written);
}

static napi_value JsCloseConn(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    return makeInt32(env, CloseConn(handle));
}

static napi_value JsCloseListener(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handle = getInt64Arg(env, args[0]);
    return makeInt32(env, CloseListener(handle));
}

static napi_value JsClose(napi_env env, napi_callback_info info) {
    return makeInt32(env, Close());
}

static napi_value JsIsStarted(napi_env env, napi_callback_info info) {
    return makeInt32(env, IsStarted());
}

/* ---------- module registration ---------- */

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, JsStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSelfInfo", nullptr, JsGetSelfInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPeers", nullptr, JsGetPeers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dial", nullptr, JsDial, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"listen", nullptr, JsListen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"accept", nullptr, JsAccept, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, JsRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"write", nullptr, JsWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeConn", nullptr, JsCloseConn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeListener", nullptr, JsCloseListener, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, JsClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isStarted", nullptr, JsIsStarted, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
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
