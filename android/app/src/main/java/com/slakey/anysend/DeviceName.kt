package com.slakey.anysend

import android.content.Context
import android.os.Build

/**
 * User-defined device name shown to peers over the LocalSend protocol.
 * Falls back to the device model when the user has not set one.
 */
object DeviceName {
    private const val KEY = "device_name"
    private const val PREFS = "tslsb"

    fun get(context: Context): String {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, "")?.trim().orEmpty()
        return saved.ifEmpty { Build.MODEL }
    }

    fun save(context: Context, name: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, name.trim()).apply()
    }
}
