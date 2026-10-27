package com.slakey.anysend.remote

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.slakey.anysend.R

/**
 * Android as the controlling end of a Mac.
 *
 * The whole video area is a direct touch surface (tap = click, drag = drag,
 * two fingers = scroll); the bottom deck adds a key row and a text box that
 * injects UTF-8 straight into the Mac.
 */
class RemoteMacActivity : AppCompatActivity(), SurfaceHolder.Callback {

    companion object {
        const val EXTRA_HOST = "host"
        const val EXTRA_PIN = "pin"

        fun intent(context: Context, host: String, pin: String): Intent =
            Intent(context, RemoteMacActivity::class.java)
                .putExtra(EXTRA_HOST, host)
                .putExtra(EXTRA_PIN, pin)
    }

    private lateinit var surfaceView: SurfaceView
    private lateinit var touchLayer: View
    private lateinit var videoContainer: FrameLayout
    private lateinit var tvConnecting: TextView
    private lateinit var tvTitle: TextView
    private lateinit var inputRow: View
    private lateinit var etText: EditText

    private var client: MacRemoteClient? = null
    private var surfaceReady = false
    private var videoWidth = 0
    private var videoHeight = 0
    private var connecting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(R.layout.activity_remote_mac)

        surfaceView = findViewById(R.id.surface)
        touchLayer = findViewById(R.id.touchLayer)
        videoContainer = findViewById(R.id.videoContainer)
        tvConnecting = findViewById(R.id.tvConnecting)
        tvTitle = findViewById(R.id.tvTitle)
        inputRow = findViewById(R.id.inputRow)
        etText = findViewById(R.id.etText)

        surfaceView.holder.addCallback(this)

        findViewById<TextView>(R.id.btnClose).setOnClickListener { finish() }
        findViewById<TextView>(R.id.btnEsc).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.ESCAPE))
        }
        findViewById<TextView>(R.id.btnCmdTab).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.TAB, MacRemoteControl.Meta.META))
        }
        findViewById<TextView>(R.id.btnKeyboard).setOnClickListener {
            inputRow.visibility = if (inputRow.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            if (inputRow.visibility == View.VISIBLE) {
                etText.requestFocus()
                showKeyboard(etText)
            }
        }
        findViewById<TextView>(R.id.btnSpace).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.SPACE))
        }
        findViewById<TextView>(R.id.btnBackspace).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.DEL))
        }
        findViewById<TextView>(R.id.btnLeft).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.DPAD_LEFT))
        }
        findViewById<TextView>(R.id.btnUp).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.DPAD_UP))
        }
        findViewById<TextView>(R.id.btnDown).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.DPAD_DOWN))
        }
        findViewById<TextView>(R.id.btnRight).setOnClickListener {
            send(MacRemoteControl.keyPair(MacRemoteControl.KeyCode.DPAD_RIGHT))
        }
        findViewById<TextView>(R.id.btnSendText).setOnClickListener {
            val text = etText.text.toString()
            if (text.isNotEmpty()) {
                send(listOf(MacRemoteControl.text(text)))
                etText.setText("")
            }
        }
        etText.setOnEditorActionListener { _, _, _ ->
            val text = etText.text.toString()
            if (text.isNotEmpty()) {
                send(listOf(MacRemoteControl.text(text)))
                etText.setText("")
            }
            true
        }

        touchLayer.setOnTouchListener { _, event -> handleTouch(event) }

        // The soft keyboard shrinks the video container, so the letterbox has to
        // be recomputed on every layout pass.
        videoContainer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            applyAspect()
        }

        val host = intent.getStringExtra(EXTRA_HOST).orEmpty()
        val pin = intent.getStringExtra(EXTRA_PIN).orEmpty()
        tvTitle.text = if (host.isEmpty()) "远程控制" else host

        connect(host, pin)
    }

    override fun onDestroy() {
        client?.stop()
        client = null
        super.onDestroy()
    }

    // ---------------- surface ----------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        surfaceReady = true
        startClientIfReady(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surfaceReady = false
        connecting = false
        client?.stop()
        client = null
    }

    private var pendingHost = ""
    private var pendingPin = ""

    private fun connect(host: String, pin: String) {
        pendingHost = host
        pendingPin = pin
        startClientIfReady(surfaceView.holder.surface)
    }

    private fun startClientIfReady(surface: Surface) {
        if (!surfaceReady || connecting || surface.isValid.not() || pendingHost.isEmpty()) return
        connecting = true
        tvConnecting.visibility = View.VISIBLE

        val c = MacRemoteClient(
            host = pendingHost,
            pin = pendingPin,
            surface = surface,
            onVideoSize = { width, height, name ->
                runOnUiThread {
                    videoWidth = width
                    videoHeight = height
                    if (name.isNotEmpty()) tvTitle.text = name
                    applyAspect()
                }
            },
            onError = { message ->
                runOnUiThread {
                    if (!isFinishing) {
                        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
                        finish()
                    }
                }
            },
            onFirstFrame = {
                runOnUiThread { tvConnecting.visibility = View.GONE }
            },
            onClipboard = { text ->
                runOnUiThread { copyToClipboard(text) }
            },
        )
        client = c
        c.start()
    }

    /** Letterbox the video so the Mac's resolution is never stretched. */
    private fun applyAspect() {
        if (videoWidth <= 0 || videoHeight <= 0) return
        val containerW = videoContainer.width
        val containerH = videoContainer.height
        if (containerW <= 0 || containerH <= 0) return
        val scale = minOf(
            containerW.toFloat() / videoWidth,
            containerH.toFloat() / videoHeight,
        )
        val w = (videoWidth * scale).toInt()
        val h = (videoHeight * scale).toInt()
        for (view in listOf(surfaceView, touchLayer)) {
            val lp = view.layoutParams as FrameLayout.LayoutParams
            // Re-assigning identical params would trigger requestLayout forever.
            if (lp.width == w && lp.height == h) continue
            lp.width = w
            lp.height = h
            lp.gravity = android.view.Gravity.CENTER
            view.layoutParams = lp
        }
    }

    // ---------------- input ----------------

    private var scrollAnchorY = 0f
    private var scrollAnchorX = 0f

    private fun handleTouch(event: MotionEvent): Boolean {
        val w = videoWidth
        val h = videoHeight
        if (w <= 0 || h <= 0) return true
        val viewW = touchLayer.width.coerceAtLeast(1)
        val viewH = touchLayer.height.coerceAtLeast(1)
        val x = (event.x / viewW * w).toInt().coerceIn(0, w - 1)
        val y = (event.y / viewH * h).toInt().coerceIn(0, h - 1)

        if (event.pointerCount >= 2) {
            // Two-finger drag scrolls the Mac window under the cursor.
            when (event.actionMasked) {
                MotionEvent.ACTION_POINTER_DOWN -> {
                    scrollAnchorX = event.getX(0)
                    scrollAnchorY = event.getY(0)
                }
                MotionEvent.ACTION_MOVE -> {
                    // Positive dy = fingers moving up = scroll down (natural scrolling).
                    val dy = scrollAnchorY - event.getY(0)
                    val dx = scrollAnchorX - event.getX(0)
                    scrollAnchorX = event.getX(0)
                    scrollAnchorY = event.getY(0)
                    if (dx != 0f || dy != 0f) {
                        send(
                            listOf(
                                MacRemoteControl.scroll(
                                    x, y, w, h,
                                    (dx * 2).toInt().coerceIn(-160, 160),
                                    (dy * 2).toInt().coerceIn(-160, 160),
                                )
                            )
                        )
                    }
                }
            }
            return true
        }

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> send(
                listOf(MacRemoteControl.touch(MacRemoteControl.ACTION_DOWN, 1L, x, y, w, h))
            )
            MotionEvent.ACTION_MOVE -> send(
                listOf(MacRemoteControl.touch(MacRemoteControl.ACTION_MOVE, 1L, x, y, w, h))
            )
            MotionEvent.ACTION_UP -> send(
                listOf(MacRemoteControl.touch(MacRemoteControl.ACTION_UP, 1L, x, y, w, h))
            )
            MotionEvent.ACTION_CANCEL -> send(
                listOf(MacRemoteControl.touch(MacRemoteControl.ACTION_UP, 1L, x, y, w, h))
            )
        }
        return true
    }

    /** Physical keyboards are forwarded as key code pairs with their meta state. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (etText.hasFocus()) return super.dispatchKeyEvent(event)
        // The system back button must still leave the session, never reach the Mac.
        if (event.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
        if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP || event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            return super.dispatchKeyEvent(event)
        }
        val action = when (event.action) {
            KeyEvent.ACTION_DOWN -> MacRemoteControl.ACTION_DOWN
            KeyEvent.ACTION_UP -> MacRemoteControl.ACTION_UP
            else -> return super.dispatchKeyEvent(event)
        }
        val meta = event.metaState and (
            MacRemoteControl.Meta.SHIFT or MacRemoteControl.Meta.ALT or
                MacRemoteControl.Meta.CTRL or MacRemoteControl.Meta.META
            )
        send(listOf(MacRemoteControl.keycode(action, event.keyCode, meta, event.repeatCount)))
        return true
    }

    private fun send(packets: List<ByteArray>) {
        val c = client ?: return
        for (packet in packets) c.send(packet)
    }

    private fun copyToClipboard(text: String) {
        if (text.isEmpty()) return
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        manager.setPrimaryClip(ClipData.newPlainText("Mac", text))
        Toast.makeText(this, "已同步 Mac 剪贴板", Toast.LENGTH_SHORT).show()
    }

    private fun showKeyboard(view: View) {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
        imm.showSoftInput(view, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
    }
}
