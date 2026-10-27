package com.slakey.anysend.remote

/**
 * Builds the scrcpy v2 control messages understood by the Mac host
 * (`RemoteHostController.swift`). Every field is big-endian, matching
 * `ControlPacket.ets` on the HarmonyOS side.
 */
object MacRemoteControl {

    const val ACTION_DOWN = 0
    const val ACTION_UP = 1
    const val ACTION_MOVE = 2

    /** Android key codes that the Mac keymap knows how to translate. */
    object KeyCode {
        const val ESCAPE = 111
        const val TAB = 61
        const val ENTER = 66
        const val DEL = 67
        const val SPACE = 62
        const val BACK = 4
        const val HOME = 3
        const val APP_SWITCH = 187
        const val DPAD_UP = 19
        const val DPAD_DOWN = 20
        const val DPAD_LEFT = 21
        const val DPAD_RIGHT = 22
        const val META_LEFT = 117
        const val CTRL_LEFT = 113
        const val ALT_LEFT = 57
        const val SHIFT_LEFT = 59
        const val MOVE_HOME = 122
        const val MOVE_END = 123
        const val FORWARD_DEL = 112
        const val PAGE_UP = 92
        const val PAGE_DOWN = 93
    }

    /** Meta flags; 0x10000 maps to ⌘ on the Mac side. */
    object Meta {
        const val NONE = 0
        const val SHIFT = 0x01
        const val ALT = 0x02
        const val CTRL = 0x1000
        const val META = 0x10000
    }

    fun keycode(action: Int, keycode: Int, metaState: Int = 0, repeat: Int = 0): ByteArray {
        val out = ByteArray(14)
        out[0] = 0
        out[1] = action.toByte()
        putInt(out, 2, keycode)
        putInt(out, 6, repeat)
        putInt(out, 10, metaState)
        return out
    }

    fun keyPair(keycode: Int, metaState: Int = 0): List<ByteArray> = listOf(
        keycode(ACTION_DOWN, keycode, metaState),
        keycode(ACTION_UP, keycode, metaState),
    )

    fun text(value: String): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        val out = ByteArray(5 + bytes.size)
        out[0] = 1
        putInt(out, 1, bytes.size)
        System.arraycopy(bytes, 0, out, 5, bytes.size)
        return out
    }

    fun touch(
        action: Int,
        pointerId: Long,
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        pressure: Float = 1f,
        buttons: Int = 0,
    ): ByteArray {
        val out = ByteArray(32)
        out[0] = 2
        out[1] = action.toByte()
        putLong(out, 2, pointerId)
        putInt(out, 10, x)
        putInt(out, 14, y)
        putShort(out, 18, screenWidth)
        putShort(out, 20, screenHeight)
        val clamped = pressure.coerceIn(0f, 1f)
        putShort(out, 22, (clamped * 0xFFFF).toInt())
        putInt(out, 24, 0)
        putInt(out, 28, buttons)
        return out
    }

    /**
     * Scroll deltas are signed pixel amounts on the AnySend wire format
     * (the Mac host feeds them straight into CGEvent's pixel wheel).
     */
    fun scroll(
        x: Int,
        y: Int,
        screenWidth: Int,
        screenHeight: Int,
        hScroll: Int,
        vScroll: Int,
    ): ByteArray {
        val out = ByteArray(21)
        out[0] = 3
        putInt(out, 1, x)
        putInt(out, 5, y)
        putShort(out, 9, screenWidth)
        putShort(out, 11, screenHeight)
        putShort(out, 13, hScroll.coerceIn(-32000, 32000))
        putShort(out, 15, vScroll.coerceIn(-32000, 32000))
        putInt(out, 17, 0)
        return out
    }

    // ---------------- big-endian writers ----------------

    private fun putShort(out: ByteArray, offset: Int, value: Int) {
        out[offset] = (value ushr 8).toByte()
        out[offset + 1] = value.toByte()
    }

    private fun putInt(out: ByteArray, offset: Int, value: Int) {
        out[offset] = (value ushr 24).toByte()
        out[offset + 1] = (value ushr 16).toByte()
        out[offset + 2] = (value ushr 8).toByte()
        out[offset + 3] = value.toByte()
    }

    private fun putLong(out: ByteArray, offset: Int, value: Long) {
        for (i in 0 until 8) {
            out[offset + i] = (value ushr (56 - 8 * i)).toByte()
        }
    }
}
