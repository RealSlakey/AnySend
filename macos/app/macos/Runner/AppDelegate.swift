import Cocoa
import Carbon.HIToolbox
import FlutterMacOS
import Defaults
import DockProgress
import LaunchAtLogin

enum DockIcon: CaseIterable {
    case regular
    case error
    case success
}

@main
class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var channel: FlutterMethodChannel?

    /// 远控/镜像的异步事件（错误提示）单独走一条通道。
    ///
    /// 不能复用 main-delegate-channel：那条通道在 Dart 侧注册了发送页/托盘的
    /// handler，再挂一个 handler 会把原来的顶掉。
    private var mirrorEventsChannel: FlutterMethodChannel?

    /// System-wide ⌘⇧V: hands the clipboard text straight to the send flow.
    /// Registered natively because a Flutter shortcut only fires while the app
    /// is focused, and the whole point is sending while working elsewhere.
    private var hotKeyChannel: FlutterMethodChannel?
    private var clipboardHotKey: EventHotKeyRef?
    private var pendingFilesObservation: Defaults.Observation?
    private var pendingStringsObservation: Defaults.Observation?
    private var isLaunchedAsLoginItem: Bool?
    private var pendingLoginItemResults: [FlutterResult] = []

    /// Localized labels rendered into the menu every time it opens.
    private var trayStrings: [String: String] = [:]
    private var trayAlias: String = ""
    private var trayIp: String = ""

    /// Nearby devices pushed from Flutter, shown when files are dropped on the icon.
    private var trayDevices: [[String: Any]] = []

    /// True between a drop on the status item and the device choice.
    private var trayDropActive = false
    
    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // LocalSend handles the close event manually
        return false
    }
    
    func registerMethodChannel(binaryMessenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "main-delegate-channel", binaryMessenger: binaryMessenger)
        channel?.setMethodCallHandler(handleFlutterCall)
        mirrorEventsChannel = FlutterMethodChannel(name: "anysend/android-mirror-events", binaryMessenger: binaryMessenger)
        registerClipboardHotKey(binaryMessenger: binaryMessenger)
    }

    private func registerClipboardHotKey(binaryMessenger: FlutterBinaryMessenger) {
        hotKeyChannel = FlutterMethodChannel(name: "anysend/hotkey", binaryMessenger: binaryMessenger)

        let hotKeyID = EventHotKeyID(signature: OSType(0x414E5953) /* 'ANYS' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKey
        )
        guard status == noErr else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
                var fired = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &fired
                )
                guard fired.id == 1 else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.onClipboardHotKey() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    private func onClipboardHotKey() {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the main window forward; mirror windows are separate and must
        // not steal focus here.
        if let main = NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
            main.makeKeyAndOrderFront(nil)
        }
        hotKeyChannel?.invokeMethod("sendClipboard", arguments: nil)
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = self
        
        // Brand blue shared with the Android and HarmonyOS clients (#0A59F1).
        let anySendBrandColor = NSColor(red: 10 / 255, green: 89 / 255, blue: 241 / 255, alpha: 0.9)
        DockProgress.style = .squircle(color: anySendBrandColor)
        
        isLaunchedAsLoginItem = LaunchAtLogin.wasLaunchedAtLogin
        for result in pendingLoginItemResults {
            result(isLaunchedAsLoginItem)
        }
        pendingLoginItemResults.removeAll()
        
        restoreDestinationFolderAccess()
    }
    
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLocalSendFromMenuBar()
        return false
    }
    
    private func setupPendingItemsObservation() {
        self.pendingFilesObservation = Defaults.observe(.pendingFiles) { change in
            guard !Defaults[.pendingFiles].isEmpty else { return }
            self.sendPendingItemsToFlutter()
        }
        
        self.pendingStringsObservation = Defaults.observe(.pendingStrings) { change in
            guard !Defaults[.pendingStrings].isEmpty else { return }
            self.sendPendingItemsToFlutter()
        }
    }
    
    private func setDockIcon(icon: DockIcon) {
        switch icon {
        case .regular:
            NSApplication.shared.applicationIconImage = NSImage(named: NSImage.applicationIconName)
        case .error:
            NSApplication.shared.applicationIconImage = NSImage(named: "AppIconWithErrorMark")!
        case .success:
            NSApplication.shared.applicationIconImage = NSImage(named: "AppIconWithSuccessMark")!
        }
    }
    
    private func setupStatusBarItem(i18n: [String: String]) {
        trayStrings = i18n
        // Variable length so the transfer percentage can sit next to the icon.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            let image = NSImage(named: "StatusBarItemIcon")
            image!.size = NSSize(width: 18, height: 18)
            image!.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading

            // The menu is rebuilt on open so the device name and IP stay current.
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            statusItem?.menu = menu

            let dragView = ContentDropView(frame: button.bounds)
            button.addSubview(dragView)

            dragView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dragView.topAnchor.constraint(equalTo: button.topAnchor),
                dragView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dragView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dragView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if trayDropActive {
            buildDropMenu(menu)
            return
        }

        let openItem = NSMenuItem(title: trayStrings["open"] ?? "Open AnySend", action: #selector(showLocalSendFromMenuBar), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        if !trayAlias.isEmpty {
            let nameItem = NSMenuItem(title: "\(trayStrings["localName"] ?? "Device name"): \(trayAlias)", action: nil, keyEquivalent: "")
            nameItem.isEnabled = false
            menu.addItem(nameItem)
        }
        if !trayIp.isEmpty {
            let ipItem = NSMenuItem(title: "\(trayStrings["localIp"] ?? "Device IP"): \(trayIp)", action: #selector(copyLocalIp), keyEquivalent: "")
            ipItem.target = self
            ipItem.toolTip = trayStrings["copyIp"]
            menu.addItem(ipItem)
        }
        if !trayAlias.isEmpty || !trayIp.isEmpty {
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: trayStrings["settings"] ?? "Settings…", action: #selector(openSettingsFromTray), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: trayStrings["quit"] ?? "Quit AnySend", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Menu shown after files have been dropped onto the icon: pick a target
    /// device and the transfer starts without opening the main window.
    private func buildDropMenu(_ menu: NSMenu) {
        let header = NSMenuItem(title: trayStrings["dropSendTo"] ?? "Send to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if trayDevices.isEmpty {
            let empty = NSMenuItem(title: trayStrings["dropNoDevices"] ?? "No devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for device in trayDevices {
                let title = (device["name"] as? String) ?? "Unknown"
                let item = NSMenuItem(title: title, action: #selector(sendToTrayDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device["id"] as? String
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: trayStrings["dropOpenApp"] ?? "Open AnySend…", action: #selector(openAfterTrayDrop), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let cancelItem = NSMenuItem(title: trayStrings["dropCancel"] ?? "Cancel", action: #selector(cancelTrayDrop), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)
    }

    /// Called by the status item's drop view right after the files were queued.
    func presentTrayDrop() {
        trayDropActive = true
        // Load the files into the app state first, then show the device list.
        sendPendingItemsToFlutter(showWindow: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard self.trayDropActive else { return }
            self.statusItem?.button?.performClick(nil)
        }
    }

    @objc private func sendToTrayDevice(_ sender: NSMenuItem) {
        trayDropActive = false
        guard let deviceId = sender.representedObject as? String else { return }
        channel?.invokeMethod("sendTrayFilesToDevice", arguments: deviceId)
    }

    @objc private func openAfterTrayDrop() {
        trayDropActive = false
        channel?.invokeMethod("openSendTabFromTray", arguments: nil)
    }

    @objc private func cancelTrayDrop() {
        trayDropActive = false
    }

    func menuDidClose(_ menu: NSMenu) {
        // Clicking outside the menu counts as cancelling the pending drop.
        trayDropActive = false
    }

    @objc func showLocalSendFromMenuBar() {
        channel?.invokeMethod("showLocalSendFromMenuBar", arguments: nil)
    }

    @objc private func openSettingsFromTray() {
        channel?.invokeMethod("openSettingsFromTray", arguments: nil)
    }

    @objc private func copyLocalIp() {
        guard !trayIp.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trayIp, forType: .string)
    }

    /// Mirrors the transfer progress in the menu bar next to the icon.
    private func setStatusBarProgress(_ progress: Double?) {
        guard let button = statusItem?.button else { return }
        guard let progress = progress, progress > 0, progress < 1 else {
            button.title = ""
            return
        }
        button.title = " \(Int(progress * 100))%"
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    func sendPendingItemsToFlutter(showWindow: Bool = true) {
        let pendingFileBookmarks = Defaults[.pendingFiles]
        let pendingStrings = Defaults[.pendingStrings]
        var filePaths: [String] = []
        
        for bookmark in pendingFileBookmarks {
            if let url = SecurityScopedResourceManager.shared.startAccessing(bookmark: bookmark) {
                filePaths.append(url.path)
            }
        }
        
        if !filePaths.isEmpty {
            channel?.invokeMethod("onPendingFiles", arguments: filePaths)
        }
        if !pendingStrings.isEmpty {
            channel?.invokeMethod("onPendingStrings", arguments: pendingStrings)
        }
        
        Defaults[.pendingFiles] = []
        Defaults[.pendingStrings] = []
        
        if showWindow {
            self.showLocalSendFromMenuBar()
        }
    }
    
    // START: handle opened files
    @MainActor private func handleFlutterCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "methodChannelInitialized":
            /// Any call to the channel is dropped until methodChannelInitialized is called from Flutter
            setupPendingItemsObservation()
            result(nil)
        case "setupStatusBar":
            let i18n = call.arguments as! [String: String]
            setupStatusBarItem(i18n: i18n)
            result(nil)
        case "updateStatusBarState":
            let arguments = call.arguments as? [String: Any]
            trayAlias = arguments?["alias"] as? String ?? ""
            trayIp = arguments?["ip"] as? String ?? ""
            result(nil)
        case "updateStatusBarProgress":
            setStatusBarProgress(call.arguments as? Double)
            result(nil)
        case "updateTrayDevices":
            trayDevices = (call.arguments as? [[String: Any]]) ?? []
            result(nil)
        case "remoteHostStart":
            guard #available(macOS 12.3, *) else {
                result(FlutterError(code: "UNSUPPORTED", message: "ScreenCaptureKit requires macOS 12.3", details: nil))
                return
            }
            guard let arguments = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected remote host config", details: nil))
                return
            }
            var config = RemoteHostController.Config()
            if let videoPort = arguments["videoPort"] as? Int { config.videoPort = UInt16(videoPort) }
            if let controlPort = arguments["controlPort"] as? Int { config.controlPort = UInt16(controlPort) }
            if let maxWidth = arguments["maxWidth"] as? Int { config.maxWidth = maxWidth }
            if let fps = arguments["fps"] as? Int { config.fps = max(1, min(60, fps)) }
            if let bitrate = arguments["bitrateMbps"] as? Int { config.bitrateMbps = max(1, bitrate) }
            if let pin = arguments["pin"] as? String { config.pin = pin }
            if let clipboard = arguments["clipboard"] as? Bool { config.clipboard = clipboard }
            do {
                try RemoteHostController.shared.start(config: config)
                result(nil)
            } catch {
                result(FlutterError(code: "START_FAILED", message: error.localizedDescription, details: nil))
            }
        case "remoteHostStop":
            guard #available(macOS 12.3, *) else {
                result(nil)
                return
            }
            RemoteHostController.shared.stop()
            result(nil)
        case "remoteHostStatus":
            guard #available(macOS 12.3, *) else {
                result(["running": false])
                return
            }
            result(RemoteHostController.shared.status)
        case "remoteHostPermissions":
            result([
                "screen": CGPreflightScreenCaptureAccess(),
                "accessibility": AXIsProcessTrusted(),
            ])
        case "remoteHostPromptAccessibility":
            // Adds this exact binary to the Accessibility list, so the toggle
            // the user flips afterwards really applies to the running app.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            result(AXIsProcessTrustedWithOptions(options))
        case "remoteHostRequestScreenPermission":
            // macOS does not allow prompting for screen capture, so a denial
            // can only be fixed by the switch in System Settings. Return the
            // current state and take the user there when it is still off.
            let granted = CGPreflightScreenCaptureAccess()
            if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            result(granted)
        case "remoteHostOpenAccessibilitySettings":
            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
            result(nil)
        case "androidMirrorStart":
            guard #available(macOS 12.3, *) else {
                result(FlutterError(code: "UNSUPPORTED", message: "控制安卓需要 macOS 12.3 及以上", details: nil))
                return
            }
            guard let arguments = call.arguments as? [String: Any],
                  let host = arguments["host"] as? String,
                  !host.isEmpty
            else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少安卓设备地址", details: nil))
                return
            }
            let extra = call.arguments as? [String: Any] ?? [:]
            let mode: AndroidMirrorController.Mode
            if let pkg = extra["pkg"] as? String, !pkg.isEmpty {
                // 应用推流：窗口几何先定，安卓端据此创建虚拟显示。
                let label = (extra["label"] as? String) ?? pkg
                let width = (extra["width"] as? NSNumber)?.doubleValue ?? 414
                let height = (extra["height"] as? NSNumber)?.doubleValue ?? 860
                mode = .appStream(pkg: pkg, label: label,
                                  contentSize: CGSize(width: width, height: height))
            } else {
                mode = .mirror
            }
            AndroidMirrorController.shared.start(host: host, mode: mode) { [weak self] message in
                self?.mirrorEventsChannel?.invokeMethod("androidMirrorError", arguments: message)
            }
            result(nil)
        case "androidMirrorApps":
            guard #available(macOS 12.3, *) else {
                result(FlutterError(code: "UNSUPPORTED", message: "需要 macOS 12.3 及以上", details: nil))
                return
            }
            guard let arguments = call.arguments as? [String: Any],
                  let host = arguments["host"] as? String,
                  !host.isEmpty
            else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "缺少安卓设备地址", details: nil))
                return
            }
            let refresh = (arguments["refresh"] as? Bool) ?? false
            AndroidMirrorController.fetchApps(host: host, refresh: refresh) { outcome in
                switch outcome {
                case let .success(apps):
                    result(apps)
                case let .failure(error):
                    result(FlutterError(code: "APPS_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        case "androidMirrorStop":
            guard #available(macOS 12.3, *) else {
                result(nil)
                return
            }
            AndroidMirrorController.shared.stop()
            result(nil)
        case "androidMirrorStatus":
            guard #available(macOS 12.3, *) else {
                result(["active": false])
                return
            }
            result(AndroidMirrorController.shared.status)
        case "restoreWindowFrame":
            guard let window = mainFlutterWindow else {
                result(FlutterError(code: "WINDOW_UNAVAILABLE", message: "Main window is unavailable", details: nil))
                return
            }
            result(window.setFrameUsingName("LocalSendMainWindow"))
        case "configureWindowFrameAutosave":
            let windowFrameStorageName = "LocalSendMainWindow"
            guard let arguments = call.arguments as? [String: Any],
                  let enabled = arguments["enabled"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected window frame autosave options", details: nil))
                return
            }
            guard let window = mainFlutterWindow else {
                result(FlutterError(code: "WINDOW_UNAVAILABLE", message: "Main window is unavailable", details: nil))
                return
            }
            if enabled {
                // AppKit reloads the saved frame when enabling autosave. Keep the current placement.
                window.saveFrame(usingName: windowFrameStorageName)
                guard window.setFrameAutosaveName(windowFrameStorageName) else {
                    result(FlutterError(code: "AUTOSAVE_UNAVAILABLE", message: "Window frame autosave name is unavailable", details: nil))
                    return
                }
            } else {
                guard window.setFrameAutosaveName("") else {
                    result(FlutterError(code: "AUTOSAVE_UNAVAILABLE", message: "Could not disable window frame autosave", details: nil))
                    return
                }
                NSWindow.removeFrame(usingName: windowFrameStorageName)
            }
            result(nil)
        case "removeDestinationFolderAccess":
            removeExistingDestinationAccess()
            result(nil)
        case "persistDestinationFolderAccess":
            let folderPath = call.arguments as! String
            do {
                try saveDestinationFolderAccess(folderPath)
                result(nil)
            } catch {
                result(FlutterError(code: "REQUEST_FOLDER_ACCESS_FAILED", message: "An error occurred while requesting folder access", details: nil))
            }
        case "updateDockProgress":
            let progress = call.arguments as! Double
            DockProgress.progress = progress
            result(nil)
        case "setDockIcon":
            let newIconIndex = call.arguments as! Int
            let newIcon = DockIcon.allCases[newIconIndex]
            setDockIcon(icon: newIcon)
            result(nil)
        case "getLaunchAtLogin":
            result(LaunchAtLogin.isEnabled)
        case "setLaunchAtLogin":
            if let launchAtLogin = call.arguments as? Bool {
                LaunchAtLogin.isEnabled = launchAtLogin
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a boolean value", details: nil))
            }
        case "getLaunchAtLoginMinimized":
            result(UserDefaults.standard.bool(forKey: "launchAtLoginMinimized"))
        case "setLaunchAtLoginMinimized":
            if let launchAtLoginMinimized = call.arguments as? Bool {
                UserDefaults.standard.set(launchAtLoginMinimized, forKey: "launchAtLoginMinimized")
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a boolean value", details: nil))
            }
        case "isLaunchedAsLoginItem":
            if let isLaunchedAsLoginItem = isLaunchedAsLoginItem {
                result(isLaunchedAsLoginItem)
            } else {
                // The launch Apple event is only available in `applicationDidFinishLaunching`.
                pendingLoginItemResults.append(result)
            }
        case "isReduceMotionEnabled":
            result(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        case "openFirewallSettings":
            openFirewallSettings()
            result(nil)
        case "transliterate":
            guard let text = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a string value", details: nil))
                return
            }
            // Chinese (and other non-Latin scripts) become pinyin so the text can
            // be used as a Tailscale node name, which only accepts ASCII.
            let transform = StringTransform(rawValue: "Any-Latin; Latin-ASCII")
            result(text.applyingTransform(transform, reverse: false) ?? text)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func saveDestinationFolderAccess(_ folderPath: String) throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        Defaults[.destinationFolderBookmark] = bookmarkData
    }
    
    private func removeExistingDestinationAccess() {
        guard let existingBookmarkData = Defaults[.destinationFolderBookmark] else { return }
        if let url = SecurityScopedResourceManager.shared.startAccessing(bookmark: existingBookmarkData) {
            SecurityScopedResourceManager.shared.stopAccessing(url: url)
            Defaults[.destinationFolderBookmark] = nil
        }
    }
    
    private func restoreDestinationFolderAccess() {
        guard let bookmarkData = Defaults[.destinationFolderBookmark] else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            if !isStale {
                let _ = url.startAccessingSecurityScopedResource()
            }
        } catch {
            print("Failed to restore folder access: \(error)")
        }
    }
    
    override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        /**
         Although file URLs shared via the dock icon or the "open with" file menu item already contain access permission, we pass this through the bookmark mechanism for uniformity and readability of the code with URLs shared from the share extension.
         - SeeAlso: [Enabling App Sandbox#Enabling User-Selected File Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html#//apple_ref/doc/uid/TP40011195-CH4-SW6)
         - SeeAlso: [``Shared/createBookmarkForFile(at:)``](x-source-tag://create-bookmark-func)
         */
        if let fileBookmark = createBookmarkForFile(at: URL(fileURLWithPath: filename)) {
            Defaults[.pendingFiles].append(fileBookmark)
        }
        return true
    }
    
    override func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            if let fileBookmark = createBookmarkForFile(at: URL(fileURLWithPath: filename)) {
                Defaults[.pendingFiles].append(fileBookmark)
            }
        }
    }

    override func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                if let fileBookmark = createBookmarkForFile(at: url) {
                    Defaults[.pendingFiles].append(fileBookmark)
                }
            } else {
                Defaults[.pendingStrings].append(url.absoluteString)
            }
        }
    }
    // END: handle opened files

    /// Also handles text dropped on the Dock icon
    @objc func handleSendTextService(_ pasteboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        guard let string = pasteboard.string(forType: .string) else { return }
        Defaults[.pendingStrings].append(string)
    }
}
