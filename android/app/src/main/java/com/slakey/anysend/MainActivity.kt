package com.slakey.anysend

import android.content.Context
import android.os.Bundle
import android.os.PowerManager
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.slakey.anysend.bridge.TailscaleManager

/** Host activity: bottom navigation over the transfer / sms / settings tabs. */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        // RSA key-gen on first run; keep it off the UI thread.
        Thread { com.slakey.anysend.protocol.DeviceIdentity.init(this) }.start()

        val nav = findViewById<BottomNavigationView>(R.id.bottomNav)
        nav.setOnItemSelectedListener { item ->
            // Close any pushed sub-page (e.g. SMS settings) when switching tabs.
            supportFragmentManager.popBackStack(
                null,
                androidx.fragment.app.FragmentManager.POP_BACK_STACK_INCLUSIVE
            )
            val f: Fragment = when (item.itemId) {
                R.id.nav_devices -> DeviceFragment()
                R.id.nav_history -> HistoryFragment()
                R.id.nav_settings -> SettingsFragment()
                else -> TransferFragment()
            }
            supportFragmentManager.beginTransaction()
                .replace(R.id.fragmentContainer, f)
                .commit()
            true
        }
        if (savedInstanceState == null) {
            nav.selectedItemId = R.id.nav_transfer
        }

        val prefs = getSharedPreferences("tslsb", MODE_PRIVATE)

        // Restore the persisted connection mode and re-login if needed.
        val mode = prefs.getString(BridgeService.KEY_MODE, BridgeService.MODE_TAILSCALE)
            ?: BridgeService.MODE_TAILSCALE
        val savedKey = prefs.getString("auth_key", "").orEmpty()
        if (mode == BridgeService.MODE_TAILSCALE && !TailscaleManager.isStarted() && savedKey.isNotEmpty()) {
            AppActions.loginTailscale(this, this, savedKey) { }
        } else {
            AppActions.startBridge(this, mode)
        }

        // First launch: proactively ask for the battery-optimization whitelist
        // so the foreground service survives ROM freezing.
        if (!prefs.getBoolean("battery_prompted", false) && !isIgnoringBatteryOptimizations()) {
            prefs.edit().putBoolean("battery_prompted", true).apply()
            try {
                startActivity(
                    android.content.Intent(
                        android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        android.net.Uri.parse("package:$packageName")
                    )
                )
            } catch (e: Exception) {
                // Ignore: user can trigger it from Settings tab.
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }
}
