// Shizuku UserService：以 shell UID(2000) 读/改指定包名的 app-op 模式。
//
// 用途：非默认短信应用在 OP_WRITE_SMS 上被系统置为 ignore，写短信库会静默
// 返回 0 行。这里临时把它改成 allow，写完立刻还原原模式——不触碰默认短信
// 应用角色，因此不会像角色变更那样触发系统杀掉 App 进程。
package com.slakey.anysend;

interface ISmsAppOpsService {
    /** 指定包名上某个 app-op 的当前模式（allow/ignore/deny/default/…），取不到返回空串。 */
    String appOpsMode(String packageName, String op);

    /** 设置指定包名上某个 app-op 的模式，成功返回 true。 */
    boolean setAppOpsMode(String packageName, String op, String mode);
}
