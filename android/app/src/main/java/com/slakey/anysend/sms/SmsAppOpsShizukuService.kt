package com.slakey.anysend.sms

import com.slakey.anysend.ISmsAppOpsService
import java.util.concurrent.TimeUnit

/**
 * Shizuku UserService 跑在 shell UID(2000)，是唯一能安全改 app-op 的地方。
 *
 * 复用 MirrorShizukuService 里已验证的子进程范式（/system/bin/cmd 子进程），
 * 而不是在进程内反射 AppOpsManager —— shell UID 直接调 Settings/AppOps 的
 * Java API 会因「包名与 UID 不匹配」被拒，走 cmd 子进程才稳。
 */
class SmsAppOpsShizukuService : ISmsAppOpsService.Stub() {

    companion object {
        private const val TAG = "SmsAppOps"
        private const val CMD = "/system/bin/cmd"
        private const val CMD_TIMEOUT_SEC = 5L
    }

    override fun appOpsMode(packageName: String, op: String): String {
        if (packageName.isBlank() || op.isBlank()) return ""
        val out = runCmd("appops", "get", packageName, op)
        // 输出形如 "WRITE_SMS: ignore; time=+3m42s861ms ago; rejectTime=..."
        val line = out.lineSequence().firstOrNull { it.trimStart().startsWith("$op:") } ?: return ""
        return line.substringAfter(':').substringBefore(';').trim()
    }

    override fun setAppOpsMode(packageName: String, op: String, mode: String): Boolean {
        if (packageName.isBlank() || op.isBlank() || mode.isBlank()) return false
        val out = runCmd("appops", "set", packageName, op, mode)
        return !out.contains("Error", ignoreCase = true) &&
            !out.contains("Exception", ignoreCase = true)
    }

    private fun runCmd(vararg args: String): String {
        return try {
            val proc = ProcessBuilder(CMD, *args)
                .redirectErrorStream(true)
                .start()
            if (!proc.waitFor(CMD_TIMEOUT_SEC, TimeUnit.SECONDS)) {
                proc.destroyForcibly()
                android.util.Log.w(TAG, "cmd 超时: ${args.joinToString(" ")}")
                ""
            } else {
                proc.inputStream.bufferedReader().readText().trim()
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "cmd 失败: ${args.joinToString(" ")} -> ${e.message}")
            ""
        }
    }
}
