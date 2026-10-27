import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('main-delegate-channel');

/// Mac acting as the controlled end (screen sharing from the mobile clients).
///
/// The native side speaks the same wire protocol as the scrcpy client already
/// used by the Android / HarmonyOS apps, so no new decoder is needed.
class RemoteHostStatus {
  const RemoteHostStatus({
    required this.running,
    required this.videoConnected,
    required this.controlConnected,
    required this.width,
    required this.height,
    required this.fps,
    required this.screenPermission,
    required this.accessibilityPermission,
    this.lastError,
  });

  final bool running;
  final bool videoConnected;
  final bool controlConnected;
  final int width;
  final int height;
  final int fps;
  final bool screenPermission;
  final bool accessibilityPermission;
  final String? lastError;

  bool get hasClient => videoConnected;

  static const empty = RemoteHostStatus(
    running: false,
    videoConnected: false,
    controlConnected: false,
    width: 0,
    height: 0,
    fps: 0,
    screenPermission: false,
    accessibilityPermission: false,
  );

  factory RemoteHostStatus.fromMap(Map<Object?, Object?> map) {
    return RemoteHostStatus(
      running: map['running'] as bool? ?? false,
      videoConnected: map['videoConnected'] as bool? ?? false,
      controlConnected: map['controlConnected'] as bool? ?? false,
      width: map['width'] as int? ?? 0,
      height: map['height'] as int? ?? 0,
      fps: map['fps'] as int? ?? 0,
      screenPermission: map['screenPermission'] as bool? ?? false,
      accessibilityPermission: map['accessibilityPermission'] as bool? ?? false,
      lastError: map['lastError'] as String?,
    );
  }
}

class RemoteHostService {
  static const int videoPort = 27042;
  static const int controlPort = 27043;

  // Shared with the settings section so launch-time auto-start and the UI
  // read the same preferences.
  static const String keyEnabled = 'anysend_remote_host_enabled';
  static const String keyPin = 'anysend_remote_host_pin';
  static const String keyMaxWidth = 'anysend_remote_host_max_width';
  static const String keyFps = 'anysend_remote_host_fps';
  static const String keyBitrate = 'anysend_remote_host_bitrate';
  static const String keyClipboard = 'anysend_remote_host_clipboard';

  /// Re-open the listeners on app launch when the user left the host enabled.
  ///
  /// The settings page also does this, but it only runs once the user opens
  /// Settings — without this the ports stay closed after every restart and the
  /// mobile clients see a dead host. Screen recording is never re-prompted here:
  /// a missing permission just leaves the host off until the user grants it.
  static const String _keyDebug = 'anysend_remote_host_debug';

  static Future<void> autoStartIfEnabled() async {
    if (!Platform.isMacOS) return;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(keyEnabled) == true;
    var note = 'enabled=$enabled';
    await prefs.setString(_keyDebug, note);
    if (!enabled) return;

    final current = await status();
    note += ' | running=${current.running} screen=${current.screenPermission}';
    if (current.running) {
      await prefs.setString(_keyDebug, '$note | already running');
      return;
    }
    try {
      await start(
        pin: prefs.getString(keyPin) ?? '',
        maxWidth: prefs.getInt(keyMaxWidth) ?? 1920,
        fps: prefs.getInt(keyFps) ?? 25,
        bitrateMbps: prefs.getInt(keyBitrate) ?? 8,
        clipboard: prefs.getBool(keyClipboard) ?? true,
      );
      final after = await status();
      note += ' | start ok running=${after.running} err=${after.lastError}';
    } catch (e) {
      note += ' | start error: $e';
    }
    await prefs.setString(_keyDebug, note);
  }

  static Future<RemoteHostStatus> status() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('remoteHostStatus');
    return result == null ? RemoteHostStatus.empty : RemoteHostStatus.fromMap(result);
  }

  static Future<void> start({
    required String pin,
    required int maxWidth,
    required int fps,
    required int bitrateMbps,
    required bool clipboard,
  }) async {
    await _channel.invokeMethod('remoteHostStart', {
      'videoPort': videoPort,
      'controlPort': controlPort,
      'maxWidth': maxWidth,
      'fps': fps,
      'bitrateMbps': bitrateMbps,
      'pin': pin,
      'clipboard': clipboard,
    });
  }

  static Future<void> stop() async {
    await _channel.invokeMethod('remoteHostStop');
  }

  static Future<bool> requestScreenPermission() async {
    final granted = await _channel.invokeMethod<bool>('remoteHostRequestScreenPermission');
    return granted ?? false;
  }

  static Future<void> openAccessibilitySettings() async {
    // The prompt registers the running binary in the Accessibility list before
    // System Settings opens, otherwise the switch can belong to a stale entry.
    await _channel.invokeMethod<bool>('remoteHostPromptAccessibility');
    await _channel.invokeMethod('remoteHostOpenAccessibilitySettings');
  }
}
