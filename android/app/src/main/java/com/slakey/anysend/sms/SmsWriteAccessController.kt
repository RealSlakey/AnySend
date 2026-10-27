// 临时放行「写短信库」权限的入口（App 进程侧）。
//
// 背景：安卓 4.4+ 只有默认短信应用能写 content://sms。非默认应用的
// OP_WRITE_SMS 被系统置为 ignore，写入既不抛异常也不生效（影响行数 0），
// 这就是鸿蒙端标已读/删除长期无反应的根因。
//
// 做法：通过 Shizuku UserService（shell UID）临时把本应用的 OP_WRITE_SMS 改成
// allow，执行完**立即**还原成操作前的模式（通常是 ignore）。全程不动
// 「默认短信应用」角色 —— 角色变更会让系统以 permissions revoked 为由杀掉
// 本应用进程，反而打断 HTTP 服务与投屏，所以这里改 app-op 而不是借角色。
package com.slakey.anysend.sms

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.util.Log
import com.slakey.anysend.ISmsAppOpsService
import rikka.shizuku.Shizuku
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object SmsWriteAccessController {

    private const val TAG = "SmsAppOps"
    private const val OP_WRITE_SMS = "WRITE_SMS"
    private const val MODE_ALLOW = "allow"
    private const val USER_SERVICE_VERSION = 1
    // Shizuku 首次拉起 UserService 要新建进程，且管理端可能正被 ROM 冻结；
    // 实测第一个 3s 不够（超时后进程都不会出现），给足预算并允许重试。
    private const val BIND_TIMEOUT_MS = 10000L
    private const val BIND_ATTEMPTS = 2

    @Volatile
    private var service: ISmsAppOpsService? = null
    private var conn: ServiceConnection? = null

    /**
     * 临时放行写短信并执行 [action]，结束后还原 app-op 原模式。
     *
     * 返回 false 表示「没写成」——不再像以前那样把失败静默吞掉。
     */
    fun withSmsWriteAccess(context: Context, action: () -> Boolean): Boolean {
        val pkg = context.packageName
        val svc = ensureService(context) ?: run {
            Log.w(TAG, "Shizuku 不可用，无法临时放行短信写入")
            return false
        }
        val original = try {
            svc.appOpsMode(pkg, OP_WRITE_SMS)
        } catch (e: Exception) {
            Log.w(TAG, "读取 WRITE_SMS app-op 失败: ${e.message}")
            ""
        }
        if (original == MODE_ALLOW) {
            // 已经是 allow（例如本应用就是默认短信应用），直接用，无需改动。
            return action()
        }
        if (original.isEmpty()) {
            // 读不到就不乱改：宁可如实失败，也不要留下未知的权限状态。
            Log.w(TAG, "无法读取 WRITE_SMS 当前模式，放弃写入")
            return false
        }
        val granted = try {
            svc.setAppOpsMode(pkg, OP_WRITE_SMS, MODE_ALLOW)
        } catch (e: Exception) {
            Log.w(TAG, "放行 WRITE_SMS 失败: ${e.message}")
            false
        }
        if (!granted) return false
        return try {
            action()
        } finally {
            try {
                val back = svc.setAppOpsMode(pkg, OP_WRITE_SMS, original)
                Log.d(TAG, "WRITE_SMS 已还原为 $original -> $back")
            } catch (e: Exception) {
                Log.e(TAG, "还原 WRITE_SMS 失败（原模式 $original）: ${e.message}", e)
            }
        }
    }

    /** 绑定 UserService（仅首次真正绑定，之后复用同一连接）。 */
    private fun ensureService(context: Context): ISmsAppOpsService? {
        service?.let { return it }
        synchronized(this) {
            service?.let { return it }
            if (!Shizuku.pingBinder()) {
                Log.w(TAG, "Shizuku 未运行")
                return null
            }
            if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
                // 短信路径不主动弹权限框（避免用户在看短信时被打断）；权限已在
                // Shizuku 授权过即可复用。
                Log.w(TAG, "Shizuku 权限未授予")
                return null
            }
            val latch = CountDownLatch(1)
            val args = Shizuku.UserServiceArgs(
                ComponentName(context, SmsAppOpsShizukuService::class.java)
            )
                .processNameSuffix("sms_appops")
                .version(USER_SERVICE_VERSION)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    service = ISmsAppOpsService.Stub.asInterface(binder)
                    latch.countDown()
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    service = null
                }
            }
            return try {
                for (attempt in 1..BIND_ATTEMPTS) {
                    Log.d(TAG, "绑定 SmsAppOps UserService（第 $attempt 次）...")
                    Shizuku.bindUserService(args, connection)
                    if (latch.await(BIND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                        conn = connection
                        Log.d(TAG, "SmsAppOps UserService 已连接")
                        return service
                    }
                    Log.w(TAG, "绑定超时（第 $attempt 次）")
                }
                Log.w(TAG, "SmsAppOps UserService 绑定失败，短信写入放弃")
                null
            } catch (e: Exception) {
                Log.e(TAG, "绑定 SmsAppOps UserService 失败: ${e.message}", e)
                null
            }
        }
    }
}
