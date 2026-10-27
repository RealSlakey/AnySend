package com.slakey.anysend

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.slakey.anysend.bridge.TailscaleManager
import com.slakey.anysend.protocol.LanDiscovery
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Devices tab: this device + auto-discovered Tailscale peers + LAN peers. */
class DeviceFragment : Fragment() {

    private var peersJob: kotlinx.coroutines.Job? = null
    private var peers: List<TailscaleManager.PeerInfo> = emptyList()
    private var lanDevices: List<LanDiscovery.Device> = emptyList()
    private var scanning = false

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View {
        return inflater.inflate(R.layout.fragment_devices, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        view.findViewById<TextView>(R.id.tvSelfName).text = DeviceName.get(requireContext())
        view.findViewById<TextView>(R.id.tvSelfModel).text = "${Build.MODEL} · AnySend"
        refreshSelf()

        val lv = view.findViewById<ListView>(R.id.lvDevices)
        lv.setOnItemClickListener { _, _, position, _ ->
            if (position < peers.size) {
                copyIp(peers[position].tailscaleIP)
            }
        }

        val lvLan = view.findViewById<ListView>(R.id.lvLan)
        lvLan.setOnItemClickListener { _, _, position, _ ->
            if (position < lanDevices.size) {
                copyIp(lanDevices[position].ip)
            }
        }
        view.findViewById<TextView>(R.id.btnRescan).setOnClickListener { scanLan() }
    }

    override fun onResume() {
        super.onResume()
        refreshSelf()
        peersJob = viewLifecycleOwner.lifecycleScope.launch {
            while (isActive) {
                loadPeers()
                delay(10_000)
            }
        }
        scanLan()
    }

    override fun onPause() {
        super.onPause()
        peersJob?.cancel()
        peersJob = null
    }

    private fun refreshSelf() {
        view?.findViewById<TextView>(R.id.tvSelfIp)?.text =
            "IP：${AppActions.getLocalIpAddress() ?: "--"}"
        view?.findViewById<TextView>(R.id.tvSelfState)?.text =
            if (TailscaleManager.isStarted()) "Tailscale 已连接" else "Tailscale 未连接"
    }

    private fun loadPeers() {
        viewLifecycleOwner.lifecycleScope.launch {
            peers = TailscaleManager.getPeers()
            renderTailscale()
        }
    }

    private fun renderTailscale() {
        val lv = view?.findViewById<ListView>(R.id.lvDevices) ?: return
        val rows = peers.filter { it.online }.map { it.hostName to it.tailscaleIP }
        if (rows.isEmpty()) {
            lv.adapter = simpleAdapter("暂无在线设备")
            return
        }
        lv.adapter = object : ArrayAdapter<Pair<String, String>>(
            requireContext(), R.layout.device_row, R.id.tvName, rows
        ) {
            override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
                val v = convertView ?: layoutInflater.inflate(R.layout.device_row, parent, false)
                val (name, ip) = rows[position]
                v.findViewById<TextView>(R.id.tvName).text = name
                v.findViewById<TextView>(R.id.tvIp).text = ip
                v.findViewById<TextView>(R.id.tvCopy).setOnClickListener { copyIp(ip) }
                return v
            }
        }
    }

    /** UDP broadcast scan for AnySend instances on the same Wi-Fi. */
    private fun scanLan() {
        if (scanning) return
        val lv = view?.findViewById<ListView>(R.id.lvLan) ?: return
        lv.adapter = simpleAdapter("扫描中…")
        scanning = true
        viewLifecycleOwner.lifecycleScope.launch {
            try {
                val list = withContext(Dispatchers.IO) {
                    LanDiscovery.scan(requireContext())
                }
                lanDevices = list
                renderLan()
            } catch (_: Exception) {
                lanDevices = emptyList()
                renderLan()
            } finally {
                scanning = false
            }
        }
    }

    private fun renderLan() {
        val lv = view?.findViewById<ListView>(R.id.lvLan) ?: return
        if (lanDevices.isEmpty()) {
            lv.adapter = simpleAdapter("未发现设备")
            return
        }
        val rows = lanDevices.map { it.name to it.ip }
        lv.adapter = object : ArrayAdapter<Pair<String, String>>(
            requireContext(), R.layout.device_row, R.id.tvName, rows
        ) {
            override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
                val v = convertView ?: layoutInflater.inflate(R.layout.device_row, parent, false)
                val (name, ip) = rows[position]
                v.findViewById<TextView>(R.id.tvName).text = name
                v.findViewById<TextView>(R.id.tvIp).text = ip
                v.findViewById<TextView>(R.id.tvCopy).setOnClickListener { copyIp(ip) }
                return v
            }
        }
    }

    private fun simpleAdapter(text: String): ArrayAdapter<String> =
        ArrayAdapter(requireContext(), android.R.layout.simple_list_item_1, listOf(text))

    private fun copyIp(ip: String) {
        val cm = requireContext().getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("ip", ip))
        Toast.makeText(requireContext(), "已复制 $ip", Toast.LENGTH_SHORT).show()
    }
}
