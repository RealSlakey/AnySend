import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

const _channel = MethodChannel('main-delegate-channel');

/// 独立的事件通道：错误提示不能挤在 main-delegate-channel 上。
const _events = MethodChannel('anysend/android-mirror-events');

/// Mac as the *controlling* end of an Android device.
///
/// Two modes, matching the HarmonyOS 屏幕镜像 / 应用推流 pages:
///  - mirror   – stream the phone's own screen;
///  - appStream – run one package on a fresh virtual display sized to our
///                window, so the phone's own screen stays untouched.
///
/// The Android peer runs scrcpy-server through Shizuku and reports two TCP
/// endpoints from `/api/anysend/v1/mirror-prepare`. All the streaming work
/// happens in native code; this class only drives it.
class AndroidMirrorStatus {
  const AndroidMirrorStatus({
    required this.active,
    required this.name,
    required this.width,
    required this.height,
    this.appStreaming = false,
    this.error,
  });

  final bool active;
  final String name;
  final int width;
  final int height;
  final bool appStreaming;
  final String? error;

  static const empty = AndroidMirrorStatus(active: false, name: '', width: 0, height: 0);

  factory AndroidMirrorStatus.fromMap(Map<Object?, Object?> map) {
    final error = map['error'] as String?;
    return AndroidMirrorStatus(
      active: map['active'] as bool? ?? false,
      name: map['name'] as String? ?? '',
      width: map['width'] as int? ?? 0,
      height: map['height'] as int? ?? 0,
      appStreaming: map['appStreaming'] as bool? ?? false,
      error: (error == null || error.isEmpty) ? null : error,
    );
  }
}

/// One launchable app reported by the peer (`/api/anysend/v1/apps`).
class AndroidAppEntry {
  const AndroidAppEntry({required this.pkg, required this.label, this.icon});

  final String pkg;
  final String label;

  /// 96 px PNG icon, null when the peer could not read one.
  final Uint8List? icon;

  factory AndroidAppEntry.fromMap(Map<Object?, Object?> map) {
    final icon = map['icon'] as String? ?? '';
    Uint8List? bytes;
    if (icon.isNotEmpty) {
      try {
        bytes = base64Decode(icon);
      } catch (_) {
        bytes = null;
      }
    }
    return AndroidAppEntry(
      pkg: map['pkg'] as String? ?? '',
      label: map['label'] as String? ?? '',
      icon: bytes,
    );
  }
}

class AndroidMirrorService {
  /// Native side relays failures that happen before the mirror window exists.
  static void setErrorListener(void Function(String message)? listener) {
    if (listener == null) {
      _events.setMethodCallHandler(null);
      return;
    }
    _events.setMethodCallHandler((call) async {
      if (call.method == 'androidMirrorError') {
        listener(call.arguments as String? ?? '连接失败');
      }
      return null;
    });
  }

  /// Whole-screen mirror.
  static Future<void> start(String host) async {
    await _channel.invokeMethod('androidMirrorStart', {'host': host});
  }

  /// App streaming: the native window is created at [appStreamSize] points and
  /// the Android virtual display is derived from exactly that size, so the
  /// stream fills the window with no letterboxing.
  static Future<void> startApp(String host, AndroidAppEntry app) async {
    final size = appStreamSize();
    await _channel.invokeMethod('androidMirrorStart', {
      'host': host,
      'pkg': app.pkg,
      'label': app.label,
      'width': size.width,
      'height': size.height,
    });
  }

  /// Window geometry for app streaming, in logical points.
  ///
  /// Kept phone-shaped but bounded by the current screen: the native side turns
  /// this into `new_display=WxH/DPI` (× backing scale, long edge ≤ 2048), so the
  /// app's dp canvas equals the window's point size.
  static ui.Size appStreamSize() {
    final views = ui.PlatformDispatcher.instance.views;
    final screen = views.isEmpty
        ? const ui.Size(1600, 1000)
        : views.first.physicalSize / views.first.devicePixelRatio;
    final height = math.min(860.0, math.max(560.0, screen.height - 140));
    final width = math.min(470.0, math.max(360.0, height * 0.49));
    return ui.Size(width, height);
  }

  /// Launchable apps on the peer; `refresh` re-reads the inventory.
  static Future<List<AndroidAppEntry>> fetchApps(String host, {bool refresh = false}) async {
    final result = await _channel.invokeMethod<List<Object?>>('androidMirrorApps', {
      'host': host,
      'refresh': refresh,
    });
    if (result == null) return const [];
    return result
        .whereType<Map<Object?, Object?>>()
        .map(AndroidAppEntry.fromMap)
        .where((app) => app.pkg.isNotEmpty)
        .toList();
  }

  static Future<void> stop() async {
    await _channel.invokeMethod('androidMirrorStop');
  }

  static Future<AndroidMirrorStatus> status() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('androidMirrorStatus');
    return result == null ? AndroidMirrorStatus.empty : AndroidMirrorStatus.fromMap(result);
  }
}
