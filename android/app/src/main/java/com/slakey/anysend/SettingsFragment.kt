package com.slakey.anysend

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.Fragment
import com.slakey.anysend.bridge.TailscaleManager

/** Settings tab: device name, connection mode, keep-alive permissions. */
class SettingsFragment : Fragment() {

    private lateinit var etAuthKey: EditText
    private lateinit var btnLogin: Button
    private lateinit var btnStartDirect: Button
    private lateinit var etDeviceName: EditText
    private lateinit var btnSaveDeviceName: Button
    private lateinit var tvKeepAlive: TextView
    private lateinit var btnKeepAlive: Button

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return inflater.inflate(R.layout.fragment_settings, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        etAuthKey = view.findViewById(R.id.etAuthKey)
        btnLogin = view.findViewById(R.id.btnLogin)
        btnStartDirect = view.findViewById(R.id.btnStartDirect)
        etDeviceName = view.findViewById(R.id.etDeviceName)
        btnSaveDeviceName = view.findViewById(R.id.btnSaveDeviceName)
        tvKeepAlive = view.findViewById(R.id.tvKeepAlive)
        btnKeepAlive = view.findViewById(R.id.btnKeepAlive)

        val prefs = requireContext().getSharedPreferences("tslsb", Context.MODE_PRIVATE)
        etAuthKey.setText(prefs.getString("auth_key", ""))
        etDeviceName.setText(prefs.getString("device_name", ""))

        btnLogin.setOnClickListener {
            AppActions.loginTailscale(this, requireContext(), etAuthKey.text.toString().trim()) {
                Toast.makeText(requireContext(), it, Toast.LENGTH_SHORT).show()
            }
        }
        btnStartDirect.setOnClickListener { startDirect() }
        btnSaveDeviceName.setOnClickListener {
            DeviceName.save(requireContext(), etDeviceName.text.toString())
            Toast.makeText(requireContext(), "设备名已保存：${DeviceName.get(requireContext())}", Toast.LENGTH_SHORT).show()
        }
        btnKeepAlive.setOnClickListener { requestKeepAlive() }

        view.findViewById<View>(R.id.cardSms).setOnClickListener {
            parentFragmentManager.beginTransaction()
                .replace(R.id.fragmentContainer, SmsFragment())
                .addToBackStack(null)
                .commit()
        }
    }

    override fun onResume() {
        super.onResume()
        if (this::tvKeepAlive.isInitialized) {
            refreshKeepAliveSection()
        }
    }

    private fun startDirect() {
        if (AppActions.getLocalIpAddress() == null) {
            Toast.makeText(requireContext(), "未检测到局域网 IP，请检查 Wi-Fi 连接", Toast.LENGTH_SHORT).show()
            return
        }
        AppActions.startBridge(requireContext(), BridgeService.MODE_DIRECT)
        Toast.makeText(requireContext(), "接收服务已启动（直连模式）", Toast.LENGTH_SHORT).show()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = requireContext().getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(requireContext().packageName)
    }

    private fun refreshKeepAliveSection() {
        val ok = isIgnoringBatteryOptimizations()
        tvKeepAlive.text = if (ok) {
            "已加入电池优化白名单，接收服务不易被冻结"
        } else {
            "未加白，退到后台后接收服务可能被系统冻结导致断线"
        }
        btnKeepAlive.text = if (ok) "查看电池优化设置" else "申请后台常驻权限"
    }

    private fun requestKeepAlive() {
        requireContext().getSharedPreferences("tslsb", Context.MODE_PRIVATE)
            .edit().putBoolean("battery_prompted", true).apply()
        if (isIgnoringBatteryOptimizations()) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (e: Exception) {
                Toast.makeText(requireContext(), "已加白；如仍被冻结请在电池管理中允许后台运行", Toast.LENGTH_LONG).show()
            }
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${requireContext().packageName}")
                )
            )
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (e2: Exception) {
                Toast.makeText(requireContext(), "请到系统设置中允许本应用后台运行", Toast.LENGTH_LONG).show()
            }
        }
    }
}
