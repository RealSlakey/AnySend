// NAPI surface-mode H.264 decoder for the scrcpy mirror page, exported from
// libtsnapi.so as vdInit / vdPush / vdRelease.
//
// ArkTS has no low-level video decoder API on this SDK, so we wrap OH_AVCodec
// (native AVCodec Kit) in surface mode: the XComponent's surfaceId is turned
// into an OHNativeWindow via OH_NativeWindow_CreateNativeWindowFromSurfaceId.
//
// Threading contract: the codec callbacks run on internal codec threads and
// MUST NOT touch napi. Encoded chunks queue in pendingChunks (bounded) and are
// written into input buffers either directly from OnNeedInputBuffer or, if the
// queue was empty, later from vdPush on the JS thread via the cached
// outstanding buffer.

#include "napi/native_api.h"
#include <hilog/log.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <native_window/external_window.h>

#define VD_LOG_DOMAIN 0xC0DE
#define VD_LOG_TAG "AnySendVd"

#define VD_LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, VD_LOG_DOMAIN, VD_LOG_TAG, __VA_ARGS__)
#define VD_LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, VD_LOG_DOMAIN, VD_LOG_TAG, __VA_ARGS__)
#define VD_LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, VD_LOG_DOMAIN, VD_LOG_TAG, __VA_ARGS__)

// Bound on queued encoded chunks before we start dropping the oldest ones.
// At 8 Mbps a chunk is ~30 KB, so 512 chunks is several seconds of buffer.
static const size_t kMaxPendingChunks = 512;

struct PendingChunk {
    std::vector<uint8_t> data;
    uint32_t flags;
    int64_t pts;
};

struct DecoderState {
    std::mutex mtx;
    OH_AVCodec *codec = nullptr;
    OHNativeWindow *window = nullptr;

    std::deque<PendingChunk> pending;
    // Input buffer handed to us by OnNeedInputBuffer that we have not filled
    // yet (the queue was empty at callback time). The handle stays valid until
    // we call PushInputBuffer on it.
    bool hasOutstanding = false;
    uint32_t outstandingIndex = 0;
    OH_AVBuffer *outstandingBuffer = nullptr;
};

static DecoderState g_vd;

// Writes one chunk into an OH_AVCodec input buffer and pushes it back.
// Thread-safe (mutex held by caller); never touches napi.
static int32_t FillAndPush(OH_AVCodec *codec, PendingChunk &chunk, uint32_t index, OH_AVBuffer *buffer)
{
    uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    int32_t cap = OH_AVBuffer_GetCapacity(buffer);
    if (addr == nullptr || cap <= 0) {
        VD_LOGE("input buffer addr/cap invalid cap=%{public}d", cap);
        return -3;
    }
    if ((int32_t)chunk.data.size() > cap) {
        VD_LOGE("chunk size %{public}zu exceeds input capacity %{public}d", chunk.data.size(), cap);
        return -4;
    }
    memcpy(addr, chunk.data.data(), chunk.data.size());

    OH_AVCodecBufferAttr attr;
    attr.pts = chunk.pts;
    attr.size = (int32_t)chunk.data.size();
    attr.offset = 0;
    attr.flags = chunk.flags;
    OH_AVErrCode err = OH_AVBuffer_SetBufferAttr(buffer, &attr);
    if (err != AV_ERR_OK) {
        VD_LOGE("SetBufferAttr failed %{public}d", err);
        return -5;
    }
    err = OH_VideoDecoder_PushInputBuffer(codec, index);
    if (err != AV_ERR_OK) {
        VD_LOGE("PushInputBuffer failed %{public}d", err);
        return -6;
    }
    return 0;
}

static void OnNeedInputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    PendingChunk chunk;
    bool has = false;
    {
        std::lock_guard<std::mutex> lk(g_vd.mtx);
        if (g_vd.codec == nullptr) {
            return; // being torn down
        }
        if (!g_vd.pending.empty()) {
            chunk = std::move(g_vd.pending.front());
            g_vd.pending.pop_front();
            has = true;
        } else if (!g_vd.hasOutstanding) {
            g_vd.hasOutstanding = true;
            g_vd.outstandingIndex = index;
            g_vd.outstandingBuffer = buffer;
        }
    }
    if (has) {
        FillAndPush(codec, chunk, index, buffer);
    }
}

static void OnNewOutputBuffer(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData)
{
    // Surface mode: hand the frame to the compositor (renders to surface).
    if (codec != nullptr) {
        OH_AVErrCode err = OH_VideoDecoder_RenderOutputBuffer(codec, index);
        if (err != AV_ERR_OK) {
            VD_LOGE("RenderOutputBuffer failed %{public}d", err);
        }
    }
}

static void OnStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData)
{
    // scrcpy keeps buffer dimensions constant across rotations (crop-based),
    // so we only log; the surface keeps the configured size.
    VD_LOGI("stream changed");
}

static void OnError(OH_AVCodec *codec, int32_t errorCode, void *userData)
{
    VD_LOGE("codec error %{public}d", errorCode);
}

// Stops and destroys the codec, releases the native window, clears queues.
// Caller must hold g_vd.mtx.
static void TeardownLocked()
{
    OH_AVCodec *codec = g_vd.codec;
    g_vd.codec = nullptr; // signal callbacks first
    if (codec != nullptr) {
        OH_VideoDecoder_Stop(codec);
        OH_VideoDecoder_Destroy(codec);
    }
    if (g_vd.window != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(g_vd.window);
        g_vd.window = nullptr;
    }
    g_vd.pending.clear();
    g_vd.hasOutstanding = false;
    g_vd.outstandingBuffer = nullptr;
}

static napi_value VdNumberInt(napi_env env, int32_t v)
{
    napi_value out = nullptr;
    napi_create_int32(env, v, &out);
    return out;
}

// vdInit(surfaceId: string, width: number, height: number): number
static napi_value VdInit(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return VdNumberInt(env, -1);
    }

    size_t idLen = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &idLen);
    std::vector<char> idBuf(idLen + 1);
    size_t written = 0;
    napi_get_value_string_utf8(env, argv[0], idBuf.data(), idLen + 1, &written);

    int32_t width = 0;
    int32_t height = 0;
    napi_get_value_int32(env, argv[1], &width);
    napi_get_value_int32(env, argv[2], &height);

    uint64_t surfaceId = strtoull(idBuf.data(), nullptr, 10);

    std::lock_guard<std::mutex> lk(g_vd.mtx);
    TeardownLocked();

    OHNativeWindow *window = nullptr;
    int32_t werr = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
    if (werr != 0 || window == nullptr) {
        VD_LOGE("CreateNativeWindowFromSurfaceId failed %{public}d", werr);
        return VdNumberInt(env, -2);
    }
    g_vd.window = window;

    OH_AVCodec *codec = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC);
    if (codec == nullptr) {
        VD_LOGE("CreateByMime avc failed");
        TeardownLocked();
        return VdNumberInt(env, -2);
    }
    g_vd.codec = codec;

    // Order matters on this ROM (AV_ERR_INVALID_STATE 8 otherwise):
    // Create → RegisterCallback → Configure → SetSurface → Prepare → Start.
    // SetSurface is only accepted once the codec reached the Configured
    // state; calling it right after Create (Initialized) fails.
    OH_AVCodecCallback cb;
    cb.onError = OnError;
    cb.onStreamChanged = OnStreamChanged;
    cb.onNeedInputBuffer = OnNeedInputBuffer;
    cb.onNewOutputBuffer = OnNewOutputBuffer;
    OH_AVErrCode err = OH_VideoDecoder_RegisterCallback(codec, cb, nullptr);
    if (err != AV_ERR_OK) {
        VD_LOGE("RegisterCallback failed %{public}d", err);
        TeardownLocked();
        return VdNumberInt(env, -2);
    }

    OH_AVFormat *format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    err = OH_VideoDecoder_Configure(codec, format);
    OH_AVFormat_Destroy(format);
    if (err != AV_ERR_OK) {
        VD_LOGE("Configure failed %{public}d", err);
        TeardownLocked();
        return VdNumberInt(env, -2);
    }

    err = OH_VideoDecoder_SetSurface(codec, g_vd.window);
    if (err != AV_ERR_OK) {
        VD_LOGE("SetSurface failed %{public}d", err);
        TeardownLocked();
        return VdNumberInt(env, -2);
    }

    err = OH_VideoDecoder_Prepare(codec);
    if (err != AV_ERR_OK) {
        VD_LOGE("Prepare failed %{public}d", err);
        TeardownLocked();
        return VdNumberInt(env, -2);
    }
    err = OH_VideoDecoder_Start(codec);
    if (err != AV_ERR_OK) {
        VD_LOGE("Start failed %{public}d", err);
        TeardownLocked();
        return VdNumberInt(env, -2);
    }

    VD_LOGI("decoder started %{public}dx%{public}d", width, height);
    return VdNumberInt(env, 0);
}

// vdPush(data: ArrayBuffer, flags: number, ptsUs: number): number
static napi_value VdPush(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return VdNumberInt(env, -1);
    }

    void *data = nullptr;
    size_t byteLen = 0;
    if (napi_get_arraybuffer_info(env, argv[0], &data, &byteLen) != napi_ok || data == nullptr) {
        return VdNumberInt(env, -1);
    }
    int32_t flags = 0;
    double ptsUs = 0;
    napi_get_value_int32(env, argv[1], &flags);
    napi_get_value_double(env, argv[2], &ptsUs);

    PendingChunk chunk;
    chunk.data.assign((uint8_t *)data, (uint8_t *)data + byteLen);
    chunk.flags = (uint32_t)flags;
    chunk.pts = (int64_t)ptsUs;

    {
        std::lock_guard<std::mutex> lk(g_vd.mtx);
        if (g_vd.codec == nullptr) {
            return VdNumberInt(env, -7);
        }
        if (g_vd.hasOutstanding) {
            PendingChunk serve = std::move(chunk);
            uint32_t idx = g_vd.outstandingIndex;
            OH_AVBuffer *buf = g_vd.outstandingBuffer;
            g_vd.hasOutstanding = false;
            g_vd.outstandingBuffer = nullptr;
            FillAndPush(g_vd.codec, serve, idx, buf);
        } else {
            if (g_vd.pending.size() >= kMaxPendingChunks) {
                g_vd.pending.pop_front();
                VD_LOGW("pending overflow, dropping oldest chunk");
            }
            g_vd.pending.push_back(std::move(chunk));
        }
    }
    return VdNumberInt(env, 0);
}

static napi_value VdRelease(napi_env env, napi_callback_info info)
{
    std::lock_guard<std::mutex> lk(g_vd.mtx);
    TeardownLocked();
    VD_LOGI("decoder released");
    return VdNumberInt(env, 0);
}

/* ---------- registration hook consumed by napi_bridge.cpp Init ---------- */

void VdRegister(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"vdInit", nullptr, VdInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vdPush", nullptr, VdPush, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vdRelease", nullptr, VdRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
}
