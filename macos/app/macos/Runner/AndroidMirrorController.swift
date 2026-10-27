//
//  AndroidMirrorController.swift
//  AnySend
//
//  Mac as the *controlling* end of an Android screen — the counterpart of the
//  HarmonyOS “远控安卓” feature. The Android peer runs scrcpy-server through its
//  Shizuku UserService and reports two TCP endpoints; this file connects to
//  them, decodes the H.264 stream and injects touch/keyboard events.
//
//  Wire protocol (scrcpy v2, byte-compatible with RemoteHostController):
//    video   1 dummy byte + 64-byte device name + 12-byte codec meta
//            (codec id / width / height, big-endian)
//            then frames: 8-byte pts+flags, 4-byte size, Annex-B payload
//    control scrcpy control messages (see ScrcpyControl below)
//
//  Endpoint discovery reuses the mobile bootstrap: POST
//  /api/anysend/v1/mirror-prepare?hs=0 to the peer's LocalSend port. `hs=0`
//  tells Android to skip the hotspot — the Mac reaches it over the tailnet.
//

import AVFoundation
import Cocoa
import Foundation
import Network

@available(macOS 12.3, *)
@MainActor
final class AndroidMirrorController: NSObject {
    static let shared = AndroidMirrorController()

    enum MirrorError: LocalizedError {
        case invalidHost
        case prepareFailed(String)
        case noBridge
        case connectFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidHost: return "设备地址无效"
            case let .prepareFailed(message): return "请求安卓端准备镜像失败：\(message)"
            case .noBridge: return "安卓端未返回镜像端口（请确认安卓端已开启 Shizuku 并允许 AnySend）"
            case let .connectFailed(message): return "连接画面失败：\(message)"
            }
        }
    }

    /// How the Android peer should run scrcpy-server.
    ///
    /// `.mirror` captures the phone's own screen. `.appStream` asks for a fresh
    /// virtual display sized to our window and launches one package on it with a
    /// START_APP control message, so the phone's own screen keeps whatever the
    /// user was doing — the same behaviour as the HarmonyOS 应用推流 page.
    enum Mode {
        case mirror
        case appStream(pkg: String, label: String, contentSize: CGSize)
    }

    private struct Endpoint {
        let host: String
        let videoPort: Int
        let controlPort: Int
        let name: String
    }

    private let queue = DispatchQueue(label: "anysend.androidmirror")
    private var window: MirrorWindow?
    private var videoConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var builder: H264SampleBuilder?
    private var headerBuffer = Data()
    private var frameBuffer = Data()
    private var headerReady = false
    private var videoWidth = 0
    private var videoHeight = 0
    private var deviceName = "安卓设备"
    private var failureHandler: ((String) -> Void)?
    private var mode: Mode = .mirror

    /// 上一次开始时的地址，窗口缩放后重建虚拟显示要用。
    private var currentHost = ""
    private var pendingRestart: DispatchWorkItem?

    /// 每次建连 / 拆连自增；旧连接的回调靠它作废，避免「主动断开」或
    /// 「缩放重建」被误判成安卓端断开而报错。
    private var generation = 0

    private(set) var active = false
    private(set) var lastError: String?

    private override init() {
        super.init()
    }

    var status: [String: Any] {
        var appStreaming = false
        if case .appStream = mode {
            appStreaming = true
        }
        return [
            "active": active,
            "name": deviceName,
            "width": videoWidth,
            "height": videoHeight,
            "appStreaming": appStreaming,
            "error": lastError ?? "",
        ]
    }

    // MARK: - Public API

    /// Resolve the Android mirror bridge for `host` (its tailnet or LAN IPv4),
    /// connect both streams and show the control window.
    func start(host: String, mode: Mode = .mirror, onFailure: ((String) -> Void)? = nil) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            onFailure?(MirrorError.invalidHost.localizedDescription)
            return
        }
        stop()
        self.mode = mode
        currentHost = host
        failureHandler = onFailure
        active = true
        lastError = nil
        deviceName = host

        prepare(host: host, mode: mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(endpoint):
                self.connect(endpoint)
            case let .failure(error):
                self.finishWith(error.localizedDescription)
            }
        }
    }

    func stop() {
        teardown(closeWindow: true)
    }

    /// `closeWindow: false` 用于「窗口自己关闭」的场景：此时再去 orderOut / 释放
    /// 这条正在关闭的窗口会让 AppKit 在 close 流程里踩到已释放对象，直接崩溃。
    private func teardown(closeWindow: Bool) {
        active = false
        generation += 1
        pendingRestart?.cancel()
        pendingRestart = nil
        videoConnection?.cancel()
        controlConnection?.cancel()
        videoConnection = nil
        controlConnection = nil
        builder = nil
        headerBuffer.removeAll()
        frameBuffer.removeAll()
        headerReady = false
        videoWidth = 0
        videoHeight = 0
        lastError = nil
        mode = .mirror
        if closeWindow {
            window?.orderOut(nil)
            window = nil
            return
        }
        // 窗口正在关闭：断开所有回调，并让它在 close 流程结束后才释放。
        let closing = window
        window?.onClose = nil
        window?.onResizeEnd = nil
        window?.onControl = nil
        window = nil
        DispatchQueue.main.async {
            _ = closing
        }
    }

    private func finishWith(_ message: String) {
        lastError = message
        active = false
        videoConnection?.cancel()
        controlConnection?.cancel()
        videoConnection = nil
        controlConnection = nil
        if let window {
            // Keep the window up so the user can read why the session ended.
            window.showError(message)
        } else {
            failureHandler?(message)
        }
        failureHandler = nil
    }

    // MARK: - Discovery

    /// Device pairing token shared with the Android peer. The Flutter UI
    /// stores it via shared_preferences, which lands in NSUserDefaults under
    /// the "flutter." prefix — reading it here needs no channel round-trip.
    /// The Android side requires it on mirror-prepare and /apps (they start a
    /// screen-capture bridge / hand out hotspot credentials).
    fileprivate static var deviceToken: String {
        UserDefaults.standard.string(forKey: "flutter.mirror_device_token") ?? ""
    }

    fileprivate static func authorize(_ request: URLRequest) -> URLRequest {
        var request = request
        let token = deviceToken
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Relay-Token")
        }
        return request
    }

    /// Ask the Android peer to spawn scrcpy-server and report its endpoints.
    private func prepare(host: String, mode: Mode, completion: @escaping @MainActor (Result<Endpoint, Error>) -> Void) {
        var components = URLComponents(string: "http://\(host):53317/api/anysend/v1/mirror-prepare")
        var query: [URLQueryItem] = [URLQueryItem(name: "hs", value: "0")]
        // 应用推流：让安卓端在新建的虚拟显示上跑，并按本机窗口尺寸定几何，
        // 这样视频的宽高比与窗口一致、铺满无黑边（与鸿蒙端 harmonyVdParams 同口径）。
        if case let .appStream(_, _, contentSize) = mode {
            query.append(contentsOf: Self.virtualDisplayQuery(for: contentSize))
        }
        components?.queryItems = query
        guard let url = components?.url else {
            completion(.failure(MirrorError.invalidHost))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request = Self.authorize(request)
        // Android blocks up to ~8 s spawning the bridge; the rest is headroom.
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed(error.localizedDescription))) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed("安卓端要求配对码：在设置里填入安卓 SMS 页显示的配对码"))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed("响应不是合法 JSON"))) }
                return
            }
            let lanHost = (json["ip"] as? String) ?? ""
            let videoPort = (json["videoPort"] as? Int) ?? 0
            let controlPort = (json["controlPort"] as? Int) ?? 0
            let tailnetVideo = (json["tailnetVideoPort"] as? Int) ?? 0
            let tailnetControl = (json["tailnetControlPort"] as? Int) ?? 0
            // The phone knows its own tailnet address; our request only carried
            // its LAN IP, so prefer the address it reports back.
            let tailnetIp = (json["tailnetIp"] as? String) ?? ""

            // Same Wi-Fi as the phone: the LAN ports answer directly and avoid
            // the tailnet proxy hop. Otherwise use the proxy ports.
            let sameLan = !lanHost.isEmpty && Self.sharesSubnet(with: lanHost)
            var endpoint: Endpoint
            if sameLan && videoPort > 0 && controlPort > 0 {
                endpoint = Endpoint(host: lanHost, videoPort: videoPort, controlPort: controlPort, name: host)
            } else if tailnetVideo > 0 && tailnetControl > 0 {
                let target = tailnetIp.isEmpty ? host : tailnetIp
                endpoint = Endpoint(host: target, videoPort: tailnetVideo, controlPort: tailnetControl, name: host)
            } else if videoPort > 0 && controlPort > 0 {
                endpoint = Endpoint(host: lanHost.isEmpty ? host : lanHost, videoPort: videoPort, controlPort: controlPort, name: host)
            } else {
                Task { @MainActor in completion(.failure(MirrorError.noBridge)) }
                return
            }
            Task { @MainActor in completion(.success(endpoint)) }
        }.resume()
    }

    /// True when `other` sits in the same /24 as one of this Mac's IPv4 addresses.
    private nonisolated static func sharesSubnet(with other: String) -> Bool {
        let parts = other.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        var pointer = first
        while true {
            let entry = pointer.pointee
            if entry.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.ifa_addr, socklen_t(entry.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: hostname))
                }
            }
            guard let next = entry.ifa_next else { break }
            pointer = next
        }
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    /// Virtual-display geometry for a window of `contentSize` points.
    ///
    /// Same contract as the HarmonyOS `harmonyVdParams`: the phone runs the
    /// virtual display at our own pixel size and density, so the app's dp canvas
    /// matches the window and the stream fills it exactly. The long edge is
    /// capped at 2048 (scrcpy's `max_size`) to keep bitrate and decode cost sane.
    private nonisolated static func virtualDisplayQuery(for contentSize: CGSize) -> [URLQueryItem] {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var width = max(2, (max(contentSize.width, 1) * scale).rounded())
        var height = max(2, (max(contentSize.height, 1) * scale).rounded())
        let longest = max(width, height)
        let k = longest > 2048 ? 2048 / longest : 1
        width = max(2, (width * k).rounded())
        height = max(2, (height * k).rounded())
        let dpi = max(120, (160 * scale * k).rounded())
        return [
            URLQueryItem(name: "vd", value: "1"),
            URLQueryItem(name: "w", value: String(Int(width))),
            URLQueryItem(name: "h", value: String(Int(height))),
            URLQueryItem(name: "dpi", value: String(Int(dpi))),
        ]
    }

    /// Launchable apps on the peer for 应用推流 (pkg / label / base64 PNG icon).
    static func fetchApps(host: String, refresh: Bool, completion: @escaping @MainActor (Result<[[String: String]], Error>) -> Void) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            completion(.failure(MirrorError.invalidHost))
            return
        }
        let suffix = refresh ? "?refresh=1" : ""
        guard let url = URL(string: "http://\(host):53317/api/anysend/v1/apps\(suffix)") else {
            completion(.failure(MirrorError.invalidHost))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // ~120 base64 icons ride along; the relay can be slow.
        request.timeoutInterval = 45
        request = Self.authorize(request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed(error.localizedDescription))) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed("安卓端要求配对码：在设置里填入安卓 SMS 页显示的配对码"))) }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = json["apps"] as? [[String: Any]]
            else {
                Task { @MainActor in completion(.failure(MirrorError.prepareFailed("响应不是合法 JSON"))) }
                return
            }
            var result: [[String: String]] = []
            for app in apps {
                guard let pkg = app["pkg"] as? String, !pkg.isEmpty else { continue }
                result.append([
                    "pkg": pkg,
                    "label": (app["label"] as? String) ?? pkg,
                    "icon": (app["icon"] as? String) ?? "",
                ])
            }
            Task { @MainActor in completion(.success(result)) }
        }.resume()
    }

    // MARK: - Connections

    private func connect(_ endpoint: Endpoint) {
        deviceName = endpoint.name
        generation += 1
        let gen = generation
        let videoParams = NWParameters.tcp
        videoParams.allowLocalEndpointReuse = true
        let host = NWEndpoint.Host(endpoint.host)
        guard let videoPort = NWEndpoint.Port(rawValue: UInt16(endpoint.videoPort)),
              let controlPort = NWEndpoint.Port(rawValue: UInt16(endpoint.controlPort))
        else {
            finishWith(MirrorError.noBridge.localizedDescription)
            return
        }

        let video = NWConnection(host: host, port: videoPort, using: videoParams)
        videoConnection = video
        video.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.beginVideoRead(endpoint: endpoint, controlPort: controlPort, gen: gen)
                }
            case let .failed(error):
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.finishWith(MirrorError.connectFailed(error.localizedDescription).localizedDescription)
                }
            default:
                break
            }
        }
        video.start(queue: queue)
    }

    private func beginVideoRead(endpoint: Endpoint, controlPort: NWEndpoint.Port, gen: Int) {
        showWindow()
        receiveVideo(gen: gen)
        // scrcpy-server accepts video then control; the control socket is only
        // opened after the video one is up, which matches the server order.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let control = NWConnection(host: NWEndpoint.Host(endpoint.host), port: controlPort, using: params)
        controlConnection = control
        control.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    // 应用推流：把目标应用启动到安卓端新建的虚拟显示上。
                    // 虚拟显示模式下**不能**再发唤醒键，那会点亮用户自己的手机屏幕。
                    if case let .appStream(pkg, _, _) = self.mode {
                        self.sendControl(ScrcpyControl.startApp(pkg))
                    } else {
                        self.sendControl(ScrcpyControl.keyEventPair(keycode: ScrcpyControl.KeyCode.wakeup))
                    }
                }
            case let .failed(error):
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.finishWith(MirrorError.connectFailed(error.localizedDescription).localizedDescription)
                }
            default:
                break
            }
        }
        control.start(queue: queue)
    }

    private func receiveVideo(gen: Int) {
        videoConnection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let data, !data.isEmpty {
                    self.consume(data)
                }
                if let error {
                    self.finishWith(MirrorError.connectFailed(error.localizedDescription).localizedDescription)
                    return
                }
                if isComplete {
                    self.finishWith("安卓端已断开镜像连接")
                    return
                }
                self.receiveVideo(gen: gen)
            }
        }
    }

    // MARK: - Stream parsing

    private func consume(_ data: Data) {
        if !headerReady {
            headerBuffer.append(data)
            // 1 dummy + 64 name + 12 codec meta (id / width / height).
            guard headerBuffer.count >= 77 else { return }
            let bytes = [UInt8](headerBuffer.prefix(77))
            let nameBytes = bytes[1..<65]
            let trimmed = nameBytes.split(separator: 0, omittingEmptySubsequences: false).first ?? []
            deviceName = String(bytes: trimmed, encoding: .utf8) ?? deviceName
            let width = Int(bytes[69..<73].reduce(0) { $0 << 8 | Int($1) })
            let height = Int(bytes[73..<77].reduce(0) { $0 << 8 | Int($1) })
            guard width > 0, height > 0, width <= 8192, height <= 8192 else {
                finishWith("安卓端返回的画面尺寸异常（\(width)×\(height)）")
                return
            }
            videoWidth = width
            videoHeight = height
            // The first config packet / keyframe often rides along with the
            // header in the same TCP segment, so keep the remainder instead of
            // dropping it — otherwise the decoder never receives SPS/PPS.
            let rest = headerBuffer.count > 77 ? Data(headerBuffer[77...]) : Data()
            headerBuffer.removeAll(keepingCapacity: true)
            headerReady = true
            builder = H264SampleBuilder()
            window?.updateTitle(deviceName)
            window?.updateAspect(width: videoWidth, height: videoHeight)
            lastError = nil
            if !rest.isEmpty {
                consume(rest)
            }
            return
        }

        frameBuffer.append(data)
        while frameBuffer.count >= 12 {
            let flags = frameBuffer.withUnsafeBytes { raw -> UInt64 in
                let ptr = raw.bindMemory(to: UInt8.self)
                var value: UInt64 = 0
                for index in 0..<8 {
                    value = (value << 8) | UInt64(ptr[index])
                }
                return value
            }
            let size = frameBuffer.withUnsafeBytes { raw -> Int in
                let ptr = raw.bindMemory(to: UInt8.self)
                return Int(ptr[8]) << 24 | Int(ptr[9]) << 16 | Int(ptr[10]) << 8 | Int(ptr[11])
            }
            guard size > 0, frameBuffer.count >= 12 + size else { break }
            let payload = frameBuffer.subdata(in: 12..<(12 + size))
            frameBuffer.removeSubrange(0..<(12 + size))

            let isConfig = flags & (1 << 63) != 0
            let pts = Int64(flags & ((1 << 62) - 1))
            if isConfig {
                builder?.configure(annexB: payload)
                continue
            }
            if let sample = builder?.sample(annexB: payload, pts: pts) {
                window?.enqueue(sample)
            }
        }
    }

    // MARK: - Window

    private func showWindow() {
        if window == nil {
            let window: MirrorWindow
            switch mode {
            case .mirror:
                window = MirrorWindow(name: deviceName, mode: .mirror, contentSize: nil)
            case let .appStream(_, label, contentSize):
                // 应用推流的窗口尺寸先定好：安卓端虚拟显示就是按它换算的，
                // 画面因此 1:1 铺满窗口。
                window = MirrorWindow(name: label, mode: .appStream, contentSize: contentSize)
            }
            window.onClose = { [weak self] in
                Task { @MainActor in
                    self?.teardown(closeWindow: false)
                }
            }
            window.onControl = { [weak self] data in
                self?.sendControl(data)
            }
            // 应用推流时虚拟显示是按窗口尺寸建的，窗口缩放后必须重建，
            // 应用才会拿到新尺寸重新布局（否则只是把旧画面拉伸）。
            window.onResizeEnd = { [weak self] size in
                self?.handleWindowResize(size)
            }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sendControl(_ data: Data) {
        controlConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Resize

    /// 窗口拖拽结束后，用新尺寸重开一次虚拟显示。
    ///
    /// 安卓端的虚拟显示尺寸在 scrcpy-server 启动时就固定了，运行中无法改；
    /// 所以只能按新尺寸重建会话。窗口保留、只换视频/控制连接，用户看到的是
    /// 画面重新铺满，而不是被拉伸变形。
    private func handleWindowResize(_ size: CGSize) {
        guard case let .appStream(pkg, label, oldSize) = mode else { return }
        let width = size.width.rounded()
        let height = size.height.rounded()
        guard width >= 240, height >= 240, width <= 2048, height <= 2048 else { return }
        guard abs(width - oldSize.width) > 8 || abs(height - oldSize.height) > 8 else { return }

        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.restart(pkg: pkg, label: label, contentSize: CGSize(width: width, height: height))
            }
        }
        pendingRestart = work
        // 拖拽过程中会连续触发，等手松开稳定后再重建，避免反复重开。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func restart(pkg: String, label: String, contentSize: CGSize) {
        guard !currentHost.isEmpty else { return }
        pendingRestart = nil
        // 只断开视频/控制连接，窗口本身留着，重建后画面直接回到同一窗口。
        generation += 1
        videoConnection?.cancel()
        controlConnection?.cancel()
        videoConnection = nil
        controlConnection = nil
        builder = nil
        headerBuffer.removeAll()
        frameBuffer.removeAll()
        headerReady = false
        videoWidth = 0
        videoHeight = 0
        lastError = nil
        active = true

        let newMode = Mode.appStream(pkg: pkg, label: label, contentSize: contentSize)
        mode = newMode
        prepare(host: currentHost, mode: newMode) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(endpoint):
                self.connect(endpoint)
            case let .failure(error):
                self.finishWith(error.localizedDescription)
            }
        }
    }
}

// MARK: - Control messages (scrcpy v2)

enum ScrcpyControl {
    enum KeyCode: Int32 {
        case home = 3
        case back = 4
        case volumeUp = 24
        case volumeDown = 25
        case power = 26
        case dpadUp = 19
        case dpadDown = 20
        case dpadLeft = 21
        case dpadRight = 22
        case enter = 66
        case del = 67
        case forwardDel = 112
        case tab = 61
        case menu = 82
        case appSwitch = 187
        case wakeup = 224
    }

    enum TouchAction: UInt8 {
        case down = 0
        case up = 1
        case move = 2
        case cancel = 3
    }

    private static func be32(_ value: Int32) -> [UInt8] {
        let v = UInt32(bitPattern: value)
        return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func be64(_ value: Int64) -> [UInt8] {
        let v = UInt64(bitPattern: value)
        return (0..<8).map { UInt8((v >> (56 - $0 * 8)) & 0xFF) }
    }

    /// 1 + length(4) + UTF-8
    static func injectText(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var out: [UInt8] = [1]
        out.append(contentsOf: be32(Int32(bytes.count)))
        out.append(contentsOf: bytes)
        return Data(out)
    }

    /// 1 + action(1) + pointerId(8) + x(4) + y(4) + w(2) + h(2) + pressure(2)
    /// + actionButton(4) + buttons(4)
    static func touch(action: TouchAction, x: Int, y: Int, width: Int, height: Int,
                      pointerId: Int64 = 0, pressure: Double = 1.0) -> Data {
        var out: [UInt8] = [2, action.rawValue]
        out.append(contentsOf: be64(pointerId))
        out.append(contentsOf: be32(Int32(x)))
        out.append(contentsOf: be32(Int32(y)))
        let w = UInt16(clamping: width)
        let h = UInt16(clamping: height)
        out.append(contentsOf: [UInt8(w >> 8), UInt8(w & 0xFF)])
        out.append(contentsOf: [UInt8(h >> 8), UInt8(h & 0xFF)])
        let p = UInt16(clamping: Int((min(max(pressure, 0), 1) * 65535).rounded()))
        out.append(contentsOf: [UInt8(p >> 8), UInt8(p & 0xFF)])
        out.append(contentsOf: be32(0))
        out.append(contentsOf: be32(0))
        return Data(out)
    }

    /// 1 + x(4) + y(4) + w(2) + h(2) + hScroll(2) + vScroll(2) + buttons(4)
    static func scroll(x: Int, y: Int, width: Int, height: Int, vertical: Double) -> Data {
        var out: [UInt8] = [3]
        out.append(contentsOf: be32(Int32(x)))
        out.append(contentsOf: be32(Int32(y)))
        let w = UInt16(clamping: width)
        let h = UInt16(clamping: height)
        out.append(contentsOf: [UInt8(w >> 8), UInt8(w & 0xFF)])
        out.append(contentsOf: [UInt8(h >> 8), UInt8(h & 0xFF)])
        let clamped = min(max(vertical, -16), 16)
        let v = Int16((clamped / 16) * 32767)
        let vBits = UInt16(bitPattern: v)
        out.append(contentsOf: [0, 0])
        out.append(contentsOf: [UInt8(vBits >> 8), UInt8(vBits & 0xFF)])
        out.append(contentsOf: be32(0))
        return Data(out)
    }

    /// 0 + action(1) + keycode(4) + repeat(4) + metaState(4)
    static func keycodeMessage(_ action: UInt8, _ keycode: KeyCode, metaState: Int32 = 0) -> Data {
        var out: [UInt8] = [0, action]
        out.append(contentsOf: be32(keycode.rawValue))
        out.append(contentsOf: be32(0))
        out.append(contentsOf: be32(metaState))
        return Data(out)
    }

    static func keyEventPair(keycode: KeyCode, metaState: Int32 = 0) -> Data {
        var out = keycodeMessage(0, keycode, metaState: metaState)
        out.append(keycodeMessage(1, keycode, metaState: metaState))
        return out
    }

    /// 4 + action(1) — the server turns it into a BACK key action.
    static func backPair() -> Data {
        Data([4, 0, 4, 1])
    }

    /// 11 — rotate
    static func rotateDevice() -> Data {
        Data([11])
    }

    /// 16 + length(1) + UTF-8 package name.
    ///
    /// Launches the package on the virtual display created by `new_display=`; the
    /// phone's own screen is not affected. Mirrors HarmonyOS ControlPacket.createStartApp.
    static func startApp(_ packageName: String) -> Data {
        let bytes = Array(packageName.utf8)
        guard !bytes.isEmpty, bytes.count <= 255 else { return Data() }
        return Data([16, UInt8(bytes.count)] + bytes)
    }
}

// MARK: - Annex-B → AVCC sample builder

final class H264SampleBuilder {
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    /// Extract SPS/PPS from a config packet and (re)build the format description.
    func configure(annexB: Data) {
        for nalu in Self.nalus(annexB) {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7: sps = nalu
            case 8: pps = nalu
            default: break
            }
        }
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes: [Int] = [sps.count, pps.count]
                _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        formatDescription = description
    }

    /// Build a display-ready sample buffer from one Annex-B access unit.
    func sample(annexB: Data, pts: Int64) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        let nalus = Self.nalus(annexB)
        guard !nalus.isEmpty else { return nil }

        var avcc = Data()
        for nalu in nalus {
            let length = UInt32(nalu.count)
            avcc.append(contentsOf: [
                UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
            ])
            avcc.append(nalu)
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        let copied = avcc.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            ) == noErr
        }
        guard copied else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    /// Split an Annex-B buffer into NAL units (3- and 4-byte start codes).
    static func nalus(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        // (start of the start code, start of the NAL payload)
        var marks: [(sc: Int, payload: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                marks.append((index, index + 3))
                index += 3
            } else if index + 4 <= bytes.count,
                      bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                marks.append((index, index + 4))
                index += 4
            } else {
                index += 1
            }
        }
        guard !marks.isEmpty else {
            return bytes.isEmpty ? [] : [data]
        }
        var result: [Data] = []
        for (offset, mark) in marks.enumerated() {
            let end = offset + 1 < marks.count ? marks[offset + 1].sc : bytes.count
            guard end > mark.payload else { continue }
            result.append(Data(bytes[mark.payload..<end]))
        }
        return result
    }
}

// MARK: - Window

@available(macOS 12.3, *)
@MainActor
final class MirrorWindow: NSWindow {
    enum WindowMode {
        /// Whole-screen mirror: only a floating back arrow sits on the video.
        case mirror
        /// App streaming: only a floating ball (tap = Android back, hold = stop).
        case appStream
    }

    var onClose: (() -> Void)?
    var onControl: ((Data) -> Void)?
    /// 用户拖拽结束后的内容区尺寸（仅应用推流用到：要按它重建虚拟显示）。
    var onResizeEnd: ((CGSize) -> Void)?

    private let windowMode: WindowMode
    private let videoView = MirrorVideoView()
    private var floatingBall: FloatingBallView?

    init(name: String, mode: WindowMode, contentSize: CGSize?) {
        windowMode = mode
        let size = contentSize ?? CGSize(width: 420, height: 760)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered,
                   defer: false)
        title = mode == .mirror ? "AnySend · 屏幕镜像 · \(name)" : "AnySend · 应用推流 · \(name)"
        // 这条窗口不归 NSWindowController 管：默认关闭即释放会让 ARC 再放一次，
        // 用户点红叉时直接崩掉整个 App。
        isReleasedWhenClosed = false

        videoView.onControl = { [weak self] data in self?.onControl?(data) }
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor

        // 画面铺满整个窗口：鸿蒙端镜像/推流页也是满铺，控件浮在画面上。
        videoView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: content.topAnchor),
            videoView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        if mode == .mirror {
            // 左上角悬浮返回，对应鸿蒙镜像页的返回箭头。
            let back = FloatingBallView(symbol: "chevron.left", diameter: 32)
            back.translatesAutoresizingMaskIntoConstraints = false
            back.onTap = { [weak self] in self?.close() }
            content.addSubview(back)
            NSLayoutConstraint.activate([
                back.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                back.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            ])
        } else {
            // 应用推流：悬浮球单击注入安卓返回键，长按结束推流。
            let ball = FloatingBallView(symbol: "chevron.left", diameter: 52)
            ball.onTap = { [weak self] in self?.onControl?(ScrcpyControl.backPair()) }
            ball.onLongPress = { [weak self] in self?.close() }
            let point = FloatingBallView.defaultCenter(in: size)
            ball.setFrameOrigin(NSPoint(x: point.x - ball.frame.width / 2, y: point.y - ball.frame.height / 2))
            ball.autoresizingMask = [.minXMargin, .minYMargin]
            content.addSubview(ball)
            floatingBall = ball
        }

        self.contentView = content
        center()
        if mode == .mirror {
            setFrameAutosaveName("AnySendMirrorWindow")
        }
        delegate = self
    }

    func updateTitle(_ name: String) {
        // 应用推流的标题是应用名（窗口创建时就定好了），别被手机型号覆盖。
        if windowMode == .mirror {
            title = "AnySend · 屏幕镜像 · \(name)"
        }
    }

    func showError(_ message: String) {
        // The video layer swallows clicks; put the reason in the title bar so it
        // stays readable without a toolbar.
        title = "AnySend · \(message)"
        NSSound.beep()
    }

    /// Mirror mode: resize the content to the phone's aspect ratio.
    /// App streaming already sizes the window to the virtual display, so the
    /// aspect is fixed and the video simply fits the window.
    func updateAspect(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        videoView.videoSize = CGSize(width: width, height: height)
        guard windowMode == .mirror else { return }
        let maxHeight: CGFloat = 820
        let scale = min(1, maxHeight / CGFloat(height))
        let target = NSSize(width: max(CGFloat(width) * scale, 320), height: CGFloat(height) * scale)
        var frame = self.frame
        let delta = target.height - frame.height
        frame.size = target
        frame.origin.y -= delta
        setFrame(frame, display: true)
        relocateBall()
    }

    func enqueue(_ sample: CMSampleBuffer) {
        videoView.enqueue(sample)
    }

    /// Keep the ball inside the content area after a resize.
    private func relocateBall() {
        guard let ball = floatingBall, let content = contentView else { return }
        let bounds = content.bounds
        var origin = ball.frame.origin
        origin.x = min(max(origin.x, 12), bounds.width - ball.frame.width - 12)
        origin.y = min(max(origin.y, 12), bounds.height - ball.frame.height - 12)
        ball.setFrameOrigin(origin)
    }
}

@available(macOS 12.3, *)
extension MirrorWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    /// 悬浮球按右上角锚定，窗口放大/缩小后需要重新夹回内容区内。
    func windowDidResize(_ notification: Notification) {
        relocateBall()
    }

    /// 只在拖拽结束（或窗口自动缩放稳定）后通知一次，避免重建被连发。
    func windowDidEndLiveResize(_ notification: Notification) {
        guard windowMode == .appStream, let size = contentView?.bounds.size else { return }
        onResizeEnd?(size)
    }
}   

/// Circular on-video control: tap, hold, drag. Used for both the mirror back
/// arrow and the app-stream floating ball (matching the HarmonyOS overlay).
@available(macOS 12.3, *)
final class FloatingBallView: NSView {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    private let diameter: CGFloat
    private let imageView = NSImageView()
    private var holdTimer: Timer?
    private var longPressFired = false
    private var dragging = false
    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero

    init(symbol: String, diameter: CGFloat) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.55).cgColor
        layer?.cornerRadius = diameter / 2
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: diameter * 0.38, weight: .medium)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Right-hand, vertically centred default position (same as 鸿蒙悬浮球).
    static func defaultCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - 26 - 12, y: size.height / 2)
    }

    override func mouseDown(with event: NSEvent) {
        longPressFired = false
        dragging = false
        dragStartMouse = convert(event.locationInWindow, from: nil)
        dragStartOrigin = frame.origin
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressFired = true
            self.onLongPress?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStartMouse.x
        let dy = point.y - dragStartMouse.y
        if abs(dx) + abs(dy) > 4 {
            dragging = true
            holdTimer?.invalidate()
            holdTimer = nil
            guard let superview else { return }
            var origin = NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
            origin.x = min(max(origin.x, 12), superview.bounds.width - frame.width - 12)
            origin.y = min(max(origin.y, 12), superview.bounds.height - frame.height - 12)
            setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard !longPressFired, !dragging else { return }
        onTap?()
    }
}

/// Video surface: an `AVSampleBufferDisplayLayer` plus mouse / keyboard mapping.
@available(macOS 12.3, *)
final class MirrorVideoView: NSView {
    var onControl: ((Data) -> Void)?
    var videoSize = CGSize(width: 1080, height: 1920)

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var pressed = false
    private var lastPoint = NSPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    func enqueue(_ sample: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }

    // MARK: geometry

    /// Convert a view point (bottom-left origin) to phone pixel coordinates.
    private func phonePoint(_ event: NSEvent) -> (Int, Int) {
        let point = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        // Fit the video inside the view preserving aspect ratio.
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = bounds.width / bounds.height
        var drawWidth = bounds.width
        var drawHeight = bounds.height
        if videoAspect > viewAspect {
            drawHeight = bounds.width / videoAspect
        } else {
            drawWidth = bounds.height * videoAspect
        }
        let originX = (bounds.width - drawWidth) / 2
        let originY = (bounds.height - drawHeight) / 2
        let nx = min(max((point.x - originX) / drawWidth, 0), 1)
        let ny = min(max((point.y - originY) / drawHeight, 0), 1)
        let x = Int(nx * videoSize.width)
        let y = Int((1 - ny) * videoSize.height)
        return (x, y)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = phonePoint(event)
        pressed = true
        lastPoint = NSPoint(x: x, y: y)
        send(ScrcpyControl.touch(action: .down, x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let (x, y) = phonePoint(event)
        if abs(x - Int(lastPoint.x)) + abs(y - Int(lastPoint.y)) < 3 { return }
        lastPoint = NSPoint(x: x, y: y)
        send(ScrcpyControl.touch(action: .move, x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height)))
    }

    override func mouseUp(with event: NSEvent) {
        let (x, y) = phonePoint(event)
        pressed = false
        send(ScrcpyControl.touch(action: .up, x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height), pressure: 0))
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = phonePoint(event)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        send(ScrcpyControl.scroll(x: x, y: y, width: Int(videoSize.width), height: Int(videoSize.height), vertical: delta * 16))
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var meta: Int32 = 0
        if flags.contains(.shift) { meta |= 0x01 }
        if flags.contains(.control) { meta |= 0x1000 }
        if flags.contains(.option) { meta |= 0x02 }

        switch Int(event.keyCode) {
        case 53: // Esc → back
            send(ScrcpyControl.backPair())
            return
        case 51: // Backspace
            send(ScrcpyControl.keyEventPair(keycode: .del, metaState: meta))
            return
        case 117: // Forward delete
            send(ScrcpyControl.keyEventPair(keycode: .forwardDel, metaState: meta))
            return
        case 36, 76: // Return / keypad enter
            send(ScrcpyControl.keyEventPair(keycode: .enter, metaState: meta))
            return
        case 48: // Tab
            send(ScrcpyControl.keyEventPair(keycode: .tab, metaState: meta))
            return
        case 123:
            send(ScrcpyControl.keyEventPair(keycode: .dpadLeft, metaState: meta))
            return
        case 124:
            send(ScrcpyControl.keyEventPair(keycode: .dpadRight, metaState: meta))
            return
        case 125:
            send(ScrcpyControl.keyEventPair(keycode: .dpadDown, metaState: meta))
            return
        case 126:
            send(ScrcpyControl.keyEventPair(keycode: .dpadUp, metaState: meta))
            return
        default:
            break
        }

        guard !flags.contains(.command) else { return }
        // `charactersIgnoringModifiers` drops Shift, so keep the real characters
        // while Shift is held ("!" instead of "1").
        let typed = (flags.contains(.shift) ? event.characters : nil)
            ?? event.charactersIgnoringModifiers
            ?? event.characters
        guard let typed, !typed.isEmpty,
              let scalar = typed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else {
            return
        }
        send(ScrcpyControl.injectText(typed))
    }

    private func send(_ data: Data) {
        onControl?(data)
    }
}
