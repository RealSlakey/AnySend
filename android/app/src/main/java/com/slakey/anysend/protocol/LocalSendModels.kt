package com.slakey.anysend.protocol

import com.google.gson.annotations.SerializedName

/** LocalSend protocol constants - MUST match protocol/README.md */
object LocalSendConst {
    const val PORT = 53317
    const val PROTOCOL_VERSION = "2.0"
    const val PATH_INFO = "/api/localsend/v2/info"
    const val PATH_REGISTER = "/api/localsend/v2/register"
    const val PATH_SEND_REQUEST = "/api/localsend/v2/send-request"
    const val PATH_SEND = "/api/localsend/v2/send"
    const val PATH_CANCEL = "/api/localsend/v2/cancel"
    // Official LocalSend v2 route names (prepare-upload/upload). The legacy
    // send-request/send paths above stay for AnySend-to-AnySend transfers.
    const val PATH_PREPARE_UPLOAD = "/api/localsend/v2/prepare-upload"
    const val PATH_UPLOAD = "/api/localsend/v2/upload"
    // AnySend-specific screen-mirror bootstrap route (not part of LocalSend
    // v2): the mirroring peer asks us to raise the hotspot and report our
    // IPv4 + adbd port. Response shape is separate from the routes above.
    const val PATH_MIRROR_PREPARE = "/api/anysend/v1/mirror-prepare"
    // 应用推流：列出本机可启动的应用（包名 + 名称 + base64 PNG 图标），供鸿蒙端
    // 选一个跑在新建的虚拟显示上。与 LocalSend v2 无关，响应格式自成一类。
    const val PATH_APPS = "/api/anysend/v1/apps"
    const val DEVICE_TYPE_MOBILE = "mobile"
}

/** Device information advertised over LocalSend. */
data class DeviceInfo(
    val alias: String,
    val version: String = LocalSendConst.PROTOCOL_VERSION,
    val deviceModel: String,
    val deviceType: String,
    val fingerprint: String,
    val port: Int = LocalSendConst.PORT,
    val protocol: String = "http",
    val download: Boolean = true
)

/** A single file's metadata in a send request. */
data class FileInfo(
    val id: String,
    val fileName: String,
    val size: Long,
    val fileType: String,
    val sha256: String? = null,
    val preview: String? = null
)

/** POST /send-request body */
data class SendRequest(
    val info: DeviceInfo,
    val files: Map<String, FileInfo>
)

/** POST /send-request response: per-file decision */
data class SendRequestResponse(
    val sessionId: String,
    val files: Map<String, String> // fileId -> "accept" | "cancel"
)

/** POST /cancel body */
data class CancelRequest(
    val sessionId: String
)
