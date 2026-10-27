package com.slakey.anysend

import android.Manifest
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.fragment.app.Fragment
import com.slakey.anysend.sms.SmsRelay
import com.slakey.anysend.sms.SmsRepository

/** SMS tab: relay permissions, SIM info and the pairing token. */
class SmsFragment : Fragment() {

    private lateinit var tvSmsStatus: TextView
    private lateinit var btnSmsPerms: Button
    private lateinit var tvSmsToken: TextView

    private val smsPermissions = arrayOf(
        Manifest.permission.READ_SMS,
        Manifest.permission.SEND_SMS,
        Manifest.permission.RECEIVE_SMS,
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CONTACTS
    )

    private val smsPermsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            refresh()
            Toast.makeText(requireContext(), "权限已更新，重新启动接收服务后生效", Toast.LENGTH_SHORT).show()
        }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return inflater.inflate(R.layout.fragment_sms, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        tvSmsStatus = view.findViewById(R.id.tvSmsStatus)
        btnSmsPerms = view.findViewById(R.id.btnSmsPerms)
        tvSmsToken = view.findViewById(R.id.tvSmsToken)
        btnSmsPerms.setOnClickListener { requestSmsPermissions() }
        view.findViewById<View>(R.id.btnBack).setOnClickListener {
            parentFragmentManager.popBackStack()
        }
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        val ctx = requireContext()
        val repo = SmsRepository(ctx)
        val granted = smsPermissions.count { ContextCompat.checkSelfPermission(ctx, it) == 0 }
        val sb = StringBuilder()
        sb.append("短信权限：${granted}/${smsPermissions.size} 项已授权")
        if (repo.canRead()) {
            val sims = repo.listSims()
            if (sims.isEmpty()) {
                sb.append("\n未检测到 SIM 卡")
            } else {
                for (sim in sims) {
                    sb.append("\nSIM${sim.slotIndex}：${sim.displayName}（${sim.carrierName}）")
                }
            }
        }
        tvSmsStatus.text = sb.toString()
        btnSmsPerms.text = if (granted == smsPermissions.size) "重新授权" else "开启短信权限"
        tvSmsToken.text = "配对码：${SmsRelay(ctx).token}"
    }

    private fun requestSmsPermissions() {
        val missing = smsPermissions.filter {
            ContextCompat.checkSelfPermission(requireContext(), it) != 0
        }.toTypedArray()
        if (missing.isEmpty()) {
            Toast.makeText(requireContext(), "短信权限已全部授权", Toast.LENGTH_SHORT).show()
            return
        }
        smsPermsLauncher.launch(missing)
    }
}
