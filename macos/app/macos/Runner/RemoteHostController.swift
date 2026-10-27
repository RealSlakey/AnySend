//
//  RemoteHostController.swift
//  AnySend
//
//  Mac as the controlled end. The wire protocol is byte-compatible with the
//  scrcpy v2 client already used by the mobile apps, so the existing H.264
//  decode path works unchanged:
//
//  video  (27042)  server -> client: 1 dummy byte, 64-byte device name,
//                  12-byte codec meta (h264 / width / height)
//                  then 8-byte pts+flags, 4-byte size, Annex-B payload
//  control(27043)  client -> server: scrcpy control messages
//
//  When a PIN is configured, both connections must first send a 1-byte length
//  followed by the UTF-8 PIN. With an empty PIN the protocol stays identical
//  to scrcpy.
//

import AVFoundation
import Cocoa
import Foundation
import Network
import ScreenCaptureKit
import VideoToolbox

@available(macOS 12.3, *)
final class RemoteHostController: NSObject {
    static let shared = RemoteHostController()

    struct Config {
        var videoPort: UInt16 = 27042
        var controlPort: UInt16 = 27043
        var maxWidth: Int = 1920
        var fps: Int = 25
        var bitrateMbps: Int = 8
        var pin: String = ""
        var clipboard: Bool = true
    }

    private var config = Config()
    private var videoListener: NWListener?
    private var controlListener: NWListener?
    private var videoConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var captureSize = CGSize.zero
    private var handshakePending = false
    private var controlBuffer = Data()
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount = -1
    private let videoQueue = DispatchQueue(label: "anysend.remote.video")
    private let controlQueue = DispatchQueue(label: "anysend.remote.control")

    private(set) var running = false
    private(set) var lastError: String?
    private var accessibilityPrompted = false

    private override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func start(config: Config) throws {
        stop()
        self.config = config
        lastError = nil

        // CGPreflightScreenCaptureAccess is deprecated and reports false on
        // macOS 15+ even when TCC has already authorised the app, so it is not
        // used as a gate: capture is attempted and ScreenCaptureKit's own error
        // is reported instead of silently refusing to start.

        let videoParams = NWParameters.tcp
        videoParams.allowLocalEndpointReuse = true
        let controlParams = NWParameters.tcp
        controlParams.allowLocalEndpointReuse = true

        guard let videoPort = NWEndpoint.Port(rawValue: config.videoPort),
              let controlPort = NWEndpoint.Port(rawValue: config.controlPort)
        else {
            throw RemoteHostError.invalidPort
        }

        videoListener = try NWListener(using: videoParams, on: videoPort)
        controlListener = try NWListener(using: controlParams, on: controlPort)

        videoListener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, kind: .video)
        }
        controlListener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, kind: .control)
        }
        videoListener?.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.lastError = "\(RemoteHostController.describe(error, port: self?.config.videoPort ?? 0, kind: "视频"))"
                self?.running = false
            }
        }
        controlListener?.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.lastError = "\(RemoteHostController.describe(error, port: self?.config.controlPort ?? 0, kind: "控制"))"
            }
        }

        videoListener?.start(queue: videoQueue)
        controlListener?.start(queue: controlQueue)

        running = true
        startCapture()

        if config.clipboard {
            startClipboardWatcher()
        }
    }

    func stop() {
        running = false
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        lastClipboardChangeCount = -1

        videoConnection?.cancel()
        controlConnection?.cancel()
        videoConnection = nil
        controlConnection = nil

        videoListener?.cancel()
        controlListener?.cancel()
        videoListener = nil
        controlListener = nil

        stopCapture()
        controlBuffer.removeAll()
        handshakePending = false
    }

    var status: [String: Any] {
        [
            "running": running,
            "videoConnected": videoConnection != nil,
            "controlConnected": controlConnection != nil,
            "width": Int(captureSize.width),
            "height": Int(captureSize.height),
            "fps": config.fps,
            "videoPort": Int(config.videoPort),
            "controlPort": Int(config.controlPort),
            "screenPermission": CGPreflightScreenCaptureAccess(),
            "accessibilityPermission": RemoteHostController.isAccessibilityGranted(),
            "lastError": lastError ?? "",
        ]
    }

    /// `AXIsProcessTrusted` can keep reporting false for a while after the
    /// toggle was flipped in System Settings. Querying the AX API directly
    /// tells us whether the permission is actually usable right now.
    static func isAccessibilityGranted() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString,
            &value
        )
        return result != .apiDisabled
    }

    /// Turns a listener's NWError into something the user can act on.
    /// `EADDRINUSE` is by far the most common case in practice: a second
    /// AnySend instance (or the official LocalSend app) already owns the port.
    private static func describe(_ error: NWError, port: UInt16, kind: String) -> String {
        if case let .posix(code) = error {
            switch code {
            case .EADDRINUSE:
                return "\(kind)端口 \(port) 已被占用：另一个 AnySend（或官方 LocalSend）正在运行"
            case .EACCES:
                return "\(kind)端口 \(port) 无权限绑定"
            default:
                break
            }
        }
        return "\(kind)端口 \(port) 启动失败：\(error.localizedDescription)"
    }

    // MARK: - Capture

    /// Resolves the shareable content asynchronously: the synchronous lookup can
    /// block for seconds, and this runs on the Flutter platform thread.
    private func startCapture() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            guard self.running else { return }
            if let error = error {
                // macOS refuses to prompt for screen capture at all, so this
                // string is what the UI shows while the user flips the switch
                // in System Settings.
                self.lastError = "shareable_content: \(error.localizedDescription)"
                self.running = false
                return
            }
            guard let display = content?.displays.first else {
                self.lastError = "no_display"
                self.running = false
                return
            }
            self.startStream(display: display)
        }
    }

    private func startStream(display: SCDisplay) {
        // Keep the long edge within maxWidth so the bitrate stays reasonable.
        let screen = display.frame.size
        let scale = min(1, CGFloat(config.maxWidth) / max(screen.width, screen.height))
        var width = max(2, (screen.width * scale).rounded())
        var height = max(2, (screen.height * scale).rounded())
        // H.264 wants even dimensions.
        width = width.truncatingRemainder(dividingBy: 2) == 0 ? width : width - 1
        height = height.truncatingRemainder(dividingBy: 2) == 0 ? height : height - 1
        captureSize = CGSize(width: width, height: height)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = Int(width)
        streamConfig.height = Int(height)
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 4
        streamConfig.showsCursor = true

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        } catch {
            lastError = "add_stream_output: \(error.localizedDescription)"
            return
        }
        stream.startCapture { [weak self] error in
            if let error = error {
                self?.lastError = "start_capture: \(error.localizedDescription)"
            }
        }
        self.stream = stream

        encoder = H264Encoder(
            width: Int(width),
            height: Int(height),
            fps: config.fps,
            bitrate: config.bitrateMbps * 1_000_000
        ) { [weak self] packet in
            self?.send(video: packet)
        }

        // A client may have connected before the capture started; its handshake
        // needs the final resolution, so it waits here.
        if let connection = videoConnection {
            handshakePending = false
            sendVideoHandshake(connection)
            encoder?.requestKeyFrame()
        }
    }

    private func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
        encoder = nil
        captureSize = .zero
    }

    // MARK: - Connections

    private enum ConnectionKind {
        case video
        case control
    }

    // MARK: - PIN brute-force protection
    //
    // The PIN travels as plain bytes over raw TCP, so on a hostile LAN the
    // only thing standing between an attacker and the screen is how fast the
    // listener answers wrong guesses. Global state (not per-peer): source
    // spoofing is cheap, per-peer maps are not.

    private var authFailures = 0
    private var authBlockedUntil = Date.distantPast

    /// Exponential backoff, capped at 60 s: 1, 2, 4 ... 60 s between tries.
    private var authCooldown: TimeInterval {
        min(pow(2.0, Double(min(authFailures, 6))), 60)
    }

    /// Constant-time equality so PIN comparison timing leaks nothing.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private func accept(_ connection: NWConnection, kind: ConnectionKind) {
        let queue = kind == .video ? videoQueue : controlQueue
        connection.start(queue: queue)
        let remote = connection.currentPath?.remoteEndpoint.map { "\($0)" } ?? "?"
        diag("accept \(kind == .video ? "video" : "control") from \(remote) pinSet=\(!config.pin.isEmpty)")

        if config.pin.isEmpty {
            // Explicit operator choice, but say it out loud in the log: this
            // means anyone who can reach the ports controls this Mac.
            diag("WARNING: PIN is empty — remote control is unauthenticated")
            ready(connection, kind: kind)
            return
        }
        if Date() < authBlockedUntil {
            diag("auth blocked (cooldown) dropping \(kind == .video ? "video" : "control") from \(remote)")
            connection.cancel()
            return
        }
        authenticate(connection, kind: kind)
    }

    /// Reads a 1-byte length and the UTF-8 PIN before anything else.
    private func authenticate(_ connection: NWConnection, kind: ConnectionKind) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            guard let self = self, let lengthByte = data?.first, error == nil else {
                connection.cancel()
                return
            }
            let length = Int(lengthByte)
            guard length > 0, length <= 32 else {
                self.lastError = "bad_pin_frame"
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard let data = data, error == nil else {
                    connection.cancel()
                    return
                }
                let expected = Data(self.config.pin.utf8)
                guard Self.constantTimeEqual(data, expected) else {
                    self.authFailures += 1
                    self.authBlockedUntil = Date().addingTimeInterval(self.authCooldown)
                    self.lastError = "wrong_pin"
                    self.diag("auth failed kind=\(kind == .video ? "video" : "control") wrong_pin " +
                              "failures=\(self.authFailures) cooldown=\(Int(self.authCooldown))s")
                    connection.cancel()
                    return
                }
                self.authFailures = 0
                self.authBlockedUntil = .distantPast
                self.diag("auth ok kind=\(kind == .video ? "video" : "control")")
                self.ready(connection, kind: kind)
            }
        }
    }

    private func ready(_ connection: NWConnection, kind: ConnectionKind) {
        switch kind {
        case .video:
            videoConnection?.cancel()
            videoConnection = connection
            if captureSize == .zero {
                handshakePending = true
            } else {
                sendVideoHandshake(connection)
                // Any pending frame can be pushed immediately.
                encoder?.requestKeyFrame()
            }
        case .control:
            controlConnection?.cancel()
            controlConnection = connection
            controlBuffer.removeAll()
            receiveControl(connection)
        }
    }

    private func sendVideoHandshake(_ connection: NWConnection) {
        var data = Data()
        data.append(0) // scrcpy dummy byte
        var name = Data(repeating: 0, count: 64)
        let hostName = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let nameBytes = Array(hostName.utf8.prefix(63))
        name.replaceSubrange(0 ..< nameBytes.count, with: nameBytes)
        data.append(name)

        var meta = Data()
        meta.append(UInt8((0x68323634 >> 24) & 0xFF)) // "h264"
        meta.append(UInt8((0x68323634 >> 16) & 0xFF))
        meta.append(UInt8((0x68323634 >> 8) & 0xFF))
        meta.append(UInt8(0x68323634 & 0xFF))
        meta.append(contentsOf: be32(Int32(captureSize.width)))
        meta.append(contentsOf: be32(Int32(captureSize.height)))
        data.append(meta)

        diag("handshake send bytes=\(data.count) name='\(hostName)' size=\(Int(captureSize.width))x\(Int(captureSize.height))")
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func send(video packet: H264Encoder.Packet) {
        guard let connection = videoConnection else { return }

        var header = Data()
        var flags: UInt64 = 0
        if packet.isConfig {
            flags |= 1 << 63
        }
        if packet.isKeyFrame {
            flags |= 1 << 62
        }
        let pts = UInt64(max(0, packet.pts)) | flags
        header.append(contentsOf: be64(pts))
        header.append(contentsOf: be32(Int32(packet.data.count)))
        header.append(packet.data)

        connection.send(content: header, completion: .contentProcessed { _ in })
    }

    private func receiveControl(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection else { return }
            if let data = data, !data.isEmpty {
                self.controlBuffer.append(data)
                self.consumeControl()
            }
            if error != nil || isComplete {
                if self.controlConnection === connection {
                    self.controlConnection = nil
                }
                connection.cancel()
                return
            }
            self.receiveControl(connection)
        }
    }

    // MARK: - Control messages

    private func consumeControl() {
        while !controlBuffer.isEmpty {
            let type = controlBuffer[controlBuffer.startIndex]
            let length = controlMessageLength(type: type, buffer: controlBuffer)
            guard length > 0 else {
                // Unknown or still incomplete header: keep waiting.
                return
            }
            guard controlBuffer.count >= length else { return }
            let message = controlBuffer.prefix(length)
            controlBuffer.removeFirst(length)
            handleControl(type: type, message: Data(message))
        }
    }

    /// Returns the full message length, 0 when more bytes are needed or the
    /// message type is unknown.
    private func controlMessageLength(type: UInt8, buffer: Data) -> Int {
        let base = buffer.startIndex
        switch type {
        case 0: return 14 // inject keycode
        case 1:
            guard buffer.count >= 5 else { return 0 }
            return 5 + Int(be32At(buffer, base + 1))
        case 2: return 32 // inject touch
        case 3: return 21 // inject scroll
        case 4: return 2 // back or screen on
        case 5, 6, 7: return 1 // panels
        case 8: return 2 // get clipboard
        case 9:
            guard buffer.count >= 14 else { return 0 }
            return 14 + Int(be32At(buffer, base + 10))
        case 10: return 2 // set display power
        case 11: return 1 // rotate
        default: return 0
        }
    }

    private func handleControl(type: UInt8, message: Data) {
        let base = message.startIndex
        switch type {
        case 0:
            let action = message[base + 1]
            let keycode = Int(be32At(message, base + 2))
            let metaState = Int(be32At(message, base + 10))
            injectKey(androidKeycode: keycode, down: action == 0, metaState: metaState)
        case 1:
            let length = Int(be32At(message, base + 1))
            guard message.count >= 5 + length else { return }
            let text = String(decoding: message[(base + 5) ..< (base + 5 + length)], as: UTF8.self)
            injectText(text)
        case 2:
            let action = message[base + 1]
            let x = Int(be32At(message, base + 10))
            let y = Int(be32At(message, base + 14))
            let screenWidth = Int(be16At(message, base + 18))
            let screenHeight = Int(be16At(message, base + 20))
            // Pressure 0 on a MOVE means the client is only moving the pointer
            // (its trackpad follows the cursor), not dragging.
            let pressure = Int(be16At(message, base + 22))
            let button = Int(be32At(message, base + 24))
            injectTouch(action: action, x: x, y: y, screenWidth: screenWidth,
                        screenHeight: screenHeight, pressed: pressure > 0, button: button)
        case 3:
            let x = Int(be32At(message, base + 1))
            let y = Int(be32At(message, base + 5))
            let screenWidth = Int(be16At(message, base + 9))
            let screenHeight = Int(be16At(message, base + 11))
            // Signed: a negative delta means scrolling the other way.
            let hScroll = beI16At(message, base + 13)
            let vScroll = beI16At(message, base + 15)
            injectScroll(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight, hScroll: hScroll, vScroll: vScroll)
        case 4:
            // Back / wake: the mobile client sends a full key pair via type 0,
            // so only a wake is meaningful here.
            wakeDisplay()
        case 8:
            sendClipboardToClient()
        case 9:
            let length = Int(be32At(message, base + 10))
            guard message.count >= 14 + length else { return }
            let text = String(decoding: message[(base + 14) ..< (base + 14 + length)], as: UTF8.self)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastClipboardChangeCount = pasteboard.changeCount
        case 10:
            // macOS has no public API for switching the display off; the mobile
            // client uses its own screen lock for this, so nothing to do.
            break
        default:
            break
        }
    }

    // MARK: - Injection

    /// Raw diagnostics: unified logging redacts the payload, so the remote
    /// control path writes a plain file while it is being brought up.
    private func diag(_ line: String) {
        let path = "/tmp/anysend-rc.log"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = "[\(formatter.string(from: Date()))] " + line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Posting CGEvents is silently dropped until the app is trusted for
    /// Accessibility, so the first attempted injection asks the system to show
    /// its prompt instead of failing without any explanation.
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !accessibilityPrompted {
            accessibilityPrompted = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            // The prompt adds this binary to the Accessibility list; opening the
            // pane as well means the user lands straight on the toggle instead
            // of having to find it after dismissing the dialog.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            diag("accessibility prompt requested")
        }
        return false
    }

    private func mainDisplaySize() -> CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
    }

    /// Maps coordinates from the client's video canvas to the main display.
    private func mapPoint(x: Int, y: Int, screenWidth: Int, screenHeight: Int) -> CGPoint {
        let display = mainDisplaySize()
        guard screenWidth > 0, screenHeight > 0 else { return .zero }
        let nx = CGFloat(x) / CGFloat(screenWidth)
        let ny = CGFloat(y) / CGFloat(screenHeight)
        return CGPoint(x: nx * display.width, y: ny * display.height)
    }

    private func injectTouch(action: UInt8, x: Int, y: Int, screenWidth: Int, screenHeight: Int,
                             pressed: Bool = true, button: Int = 0) {
        let point = mapPoint(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        let source = CGEventSource(stateID: .hidSystemState)
        _ = ensureAccessibility()
        // scrcpy button codes: 1 = primary, 2 = secondary (right).
        let isRight = button == 2
        let mouseButton: CGMouseButton = isRight ? .right : .left

        if action == 0 { // ACTION_DOWN
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: isRight ? .rightMouseDown : .leftMouseDown,
                    mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        } else if action == 1 { // ACTION_UP
            CGEvent(mouseEventSource: source, mouseType: isRight ? .rightMouseUp : .leftMouseUp,
                    mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        } else if action == 2 { // ACTION_MOVE
            let type: CGEventType = pressed
                ? (isRight ? .rightMouseDragged : .leftMouseDragged)
                : .mouseMoved
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton)?
                .post(tap: .cghidEventTap)
        }
    }

    private func injectScroll(x: Int, y: Int, screenWidth: Int, screenHeight: Int, hScroll: Int, vScroll: Int) {
        let point = mapPoint(x: x, y: y, screenWidth: screenWidth, screenHeight: screenHeight)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        // Wire value is a signed pixel delta (i16). Clamp it so a stray value
        // cannot fling the window, then flip the sign: scrcpy's positive
        // vScroll means "scroll down", CGEvent's positive means "up".
        let hPixels = max(-320, min(320, hScroll))
        let vPixels = max(-320, min(320, vScroll))
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-vPixels),
            wheel2: Int32(-hPixels),
            wheel3: 0
        )
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    private func injectText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectKey(androidKeycode: Int, down: Bool, metaState: Int) {
        guard let keyCode = RemoteKeymap.macKeyCode(forAndroid: androidKeycode) else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = RemoteKeymap.flags(forMetaState: metaState)
        event?.post(tap: .cghidEventTap)
    }

    private func wakeDisplay() {
        // A no-op key event is enough to wake the display on macOS.
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard

    private func startClipboardWatcher() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, self.controlConnection != nil else { return }
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != self.lastClipboardChangeCount else { return }
            self.lastClipboardChangeCount = pasteboard.changeCount
            self.sendClipboardToClient()
        }
    }

    func sendClipboardToClient() {
        guard let connection = controlConnection else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let bytes = Array(text.utf8.prefix(100_000))
        var data = Data()
        data.append(0) // clipboard type expected by the mobile client
        data.append(contentsOf: be32(Int32(bytes.count)))
        data.append(contentsOf: bytes)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Helpers

    private func be32(_ value: Int32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private func be64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8((value >> UInt64(8 * (7 - $0))) & 0xFF) }
    }

    private func be32At(_ data: Data, _ offset: Data.Index) -> Int32 {
        Int32(bitPattern:
            UInt32(data[offset]) << 24 |
                UInt32(data[offset + 1]) << 16 |
                UInt32(data[offset + 2]) << 8 |
                UInt32(data[offset + 3])
        )
    }

    private func be16At(_ data: Data, _ offset: Data.Index) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    /// Same bytes as `be16At`, but interpreted as a signed fixed-point value
    /// (used by the scroll event).
    private func beI16At(_ data: Data, _ offset: Data.Index) -> Int {
        Int(Int16(bitPattern: be16At(data, offset)))
    }
}

@available(macOS 12.3, *)
extension RemoteHostController: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder?.encode(pixelBuffer: pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

@available(macOS 12.3, *)
enum RemoteHostError: LocalizedError {
    case screenPermissionMissing
    case invalidPort
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .screenPermissionMissing: return "screen_permission_missing"
        case .invalidPort: return "invalid_port"
        case .noDisplay: return "no_display"
        }
    }
}

// MARK: - H.264 encoder

final class H264Encoder {
    struct Packet {
        let data: Data
        let pts: Int64
        let isKeyFrame: Bool
        let isConfig: Bool
    }

    private let width: Int
    private let height: Int
    private let fps: Int
    private let bitrate: Int
    private let onPacket: (Packet) -> Void
    private var session: VTCompressionSession?
    private var forceKeyFrame = false

    init(width: Int, height: Int, fps: Int, bitrate: Int, onPacket: @escaping (Packet) -> Void) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.onPacket = onPacket
        createSession()
    }

    private func createSession() {
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    func requestKeyFrame() {
        forceKeyFrame = true
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session = session else { return }
        var flags: VTEncodeInfoFlags = []
        let handler: VTCompressionOutputHandler = { [weak self] status, _, sampleBuffer in
            guard let self = self, status == noErr, let sampleBuffer = sampleBuffer else { return }
            self.handle(sampleBuffer: sampleBuffer)
        }
        let properties: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        } else {
            properties = nil
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: &flags,
            outputHandler: handler
        )
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let isKeyFrame = sampleBufferIsKeyFrame(sampleBuffer)

        let pts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)

        // SPS/PPS travel as a separate config packet right before a key frame so
        // the mobile decoder can rebuild its format description.
        if isKeyFrame, let config = annexBParameterSets(format: format) {
            onPacket(Packet(data: config, pts: pts, isKeyFrame: false, isConfig: true))
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
              let pointer = pointer
        else {
            return
        }
        let bytes = Data(bytes: pointer, count: total)
        onPacket(Packet(data: avccToAnnexB(bytes), pts: pts, isKeyFrame: isKeyFrame, isConfig: false))
    }

    private func sampleBufferIsKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = array.first
        else {
            return true
        }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private func annexBParameterSets(format: CMFormatDescription) -> Data? {
        var data = Data()
        for index in 0 ..< 2 {
            var pointer: UnsafePointer<UInt8>?
            var size: Int = 0
            var count: Int = 0
            var headerSize: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &headerSize
            )
            guard status == noErr, let pointer = pointer, size > 0 else { return nil }
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(pointer, count: Int(size))
        }
        return data.isEmpty ? nil : data
    }

    /// Converts 4-byte length prefixed NAL units into Annex-B.
    private func avccToAnnexB(_ data: Data) -> Data {
        var output = Data()
        var offset = 0
        while offset + 4 <= data.count {
            var nalLength = 0
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                nalLength = Int(base[0]) << 24 | Int(base[1]) << 16 | Int(base[2]) << 8 | Int(base[3])
            }
            offset += 4
            guard nalLength > 0, offset + nalLength <= data.count else { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data.subdata(in: offset ..< offset + nalLength))
            offset += nalLength
        }
        return output
    }
}

// MARK: - Key mapping

enum RemoteKeymap {
    private static let androidToMac: [Int: CGKeyCode] = [
        // Letters: Android A-Z is 29...54, macOS uses the physical key layout.
        29: 0, 30: 11, 31: 8, 32: 2, 33: 14, 34: 3, 35: 5, 36: 4, 37: 34, 38: 38,
        39: 40, 40: 37, 41: 46, 42: 45, 43: 31, 44: 35, 45: 12, 46: 15, 47: 1,
        48: 17, 49: 32, 50: 9, 51: 13, 52: 7, 53: 16, 54: 6,
        // Digits
        7: 29, 8: 18, 9: 19, 10: 20, 11: 21, 12: 23, 13: 22, 14: 26, 15: 28, 16: 25,
        // Editing and navigation
        66: 36, 67: 51, 61: 48, 62: 49, 111: 53,
        21: 123, 19: 126, 22: 124, 20: 125,
        122: 115, 123: 119, 92: 116, 93: 121, 112: 117,
        // Punctuation
        69: 27, 70: 24, 71: 33, 72: 30, 73: 42, 74: 41, 75: 39, 76: 44,
        55: 43, 56: 44, 68: 50,
        // Modifiers
        59: 56, 57: 58, 113: 59, 117: 55, 115: 57,
        // Function keys
        131: 122, 132: 120, 133: 99, 134: 118,
    ]

    static func macKeyCode(forAndroid keycode: Int) -> CGKeyCode? {
        androidToMac[keycode]
    }

    static func flags(forMetaState metaState: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if metaState & 0x1 != 0 { flags.insert(.maskShift) }
        if metaState & 0x2 != 0 { flags.insert(.maskAlternate) }
        if metaState & 0x1000 != 0 { flags.insert(.maskControl) }
        if metaState & 0x10000 != 0 { flags.insert(.maskCommand) }
        return flags
    }
}
