import 'dart:async';

import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:localsend_app/util/native/tray_helper.dart';

const _methodChannel = MethodChannel('main-delegate-channel');

Future<bool> restoreWindowFrame() async {
  return await _methodChannel.invokeMethod<bool>('restoreWindowFrame') ?? false;
}

Future<void> configureWindowFrameAutosave({required bool enabled}) async {
  await _methodChannel.invokeMethod('configureWindowFrameAutosave', {
    'enabled': enabled,
  });
}

Future<void> setupStatusBar() async {
  await _methodChannel.invokeMethod('setupStatusBar', {
    'open': t.tray.open,
    'quit': t.tray.close,
    'settings': t.tray.settings,
    'copyIp': t.tray.copyIp,
    'localName': t.tray.localName,
    'localIp': t.tray.localIp,
    'dropSendTo': t.tray.dropSendTo,
    'dropNoDevices': t.tray.dropNoDevices,
    'dropOpenApp': t.tray.dropOpenApp,
    'dropCancel': t.tray.dropCancel,
  });
}

/// Publishes the nearby devices that the tray drop menu offers.
Future<void> updateTrayDevices(List<({String id, String name})> devices) async {
  await _methodChannel.invokeMethod('updateTrayDevices', [
    for (final device in devices) {'id': device.id, 'name': device.name},
  ]);
}

/// Keeps the menu bar menu in sync with the current device name and IP.
Future<void> updateStatusBarState({required String alias, required String ip}) async {
  await _methodChannel.invokeMethod('updateStatusBarState', {
    'alias': alias,
    'ip': ip,
  });
}

/// Shows the transfer percentage next to the menu bar icon; null clears it.
Future<void> updateStatusBarProgress(double? progress) async {
  await _methodChannel.invokeMethod('updateStatusBarProgress', progress);
}

Future<void> removeExistingDestinationAccess() async {
  await _methodChannel.invokeMethod('removeExistingDestinationAccess');
}

Future<void> persistDestinationFolderAccess(String path) async {
  await _methodChannel.invokeMethod('persistDestinationFolderAccess', path);
}

Future<void> updateDockProgress(double progress) async {
  await _methodChannel.invokeMethod('updateDockProgress', progress);
}

Future<void> setLaunchAtLogin(bool value) async {
  await _methodChannel.invokeMethod('setLaunchAtLogin', value);
}

Future<bool> getLaunchAtLogin() async {
  return await _methodChannel.invokeMethod('getLaunchAtLogin');
}

Future<void> setLaunchAtLoginMinimized(bool value) async {
  await _methodChannel.invokeMethod('setLaunchAtLoginMinimized', value);
}

Future<bool> getLaunchAtLoginMinimized() async {
  return await _methodChannel.invokeMethod('getLaunchAtLoginMinimized');
}

Future<bool> isLaunchedAsLoginItem() async {
  return await _methodChannel.invokeMethod('isLaunchedAsLoginItem');
}

Future<void> setDockIcon(TaskbarIcon icon) async {
  await _methodChannel.invokeMethod('setDockIcon', icon.index);
}

Future<bool> isReduceMotionEnabledMacOs() async {
  return await _methodChannel.invokeMethod('isReduceMotionEnabled') ?? false;
}

Future<void> openFirewallSettings() async {
  await _methodChannel.invokeMethod('openFirewallSettings');
}

/// Converts non-ASCII text to Latin script (Chinese becomes pinyin).
///
/// Tailscale node names only accept ASCII, but the app's device name is free
/// text, so the two are bridged through this transliteration.
Future<String> transliterateToLatin(String text) async {
  return await _methodChannel.invokeMethod<String>('transliterate', text) ?? text;
}

// This happens:
/// - on macOS when text is dropped onto the app Dock icon
/// - on macOS when text is dropped onto the app menu bar icon
/// - on macOS when text\web link are shared to the app using the share extension (i.e. the system share menu)
final _pendingFilesStreamController = StreamController<List<String>>.broadcast();
Stream<List<String>> get pendingFilesStream => _pendingFilesStreamController.stream;

/// This happens:
/// - on macOS when text is dropped onto the app Dock icon
/// - on macOS when text is dropped onto the app menu bar icon
/// - on macOS when text\web link are shared to the app using the share extension (i.e. the system share menu)
final _pendingStringsStreamController = StreamController<List<String>>.broadcast();
Stream<List<String>> get pendingStringsStream => _pendingStringsStreamController.stream;

/// Hook set by [init] so the tray menu can deep-link into the settings tab.
Future<void> Function()? onOpenSettingsFromTray;

/// Hook set by [init] to start a transfer to [deviceId] with the files that
/// were just dropped onto the menu bar icon.
Future<void> Function(String deviceId)? onSendTrayFilesToDevice;

/// Hook set by [init] to reveal the send tab after a drop.
Future<void> Function()? onOpenSendTabFromTray;

/// Sets up the method call handler.
/// Any call from swift native code is dropped until this method is called.
Future<void> setupMethodCallHandler() async {
  _methodChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onPendingFiles':
        _pendingFilesStreamController.add((call.arguments as List).cast<String>());
        break;
      case 'onPendingStrings':
        _pendingStringsStreamController.add((call.arguments as List).cast<String>());
        break;
      case 'showLocalSendFromMenuBar':
        await showFromTray();
        break;
      case 'openSettingsFromTray':
        await onOpenSettingsFromTray?.call();
        break;
      case 'sendTrayFilesToDevice':
        await onSendTrayFilesToDevice?.call(call.arguments as String);
        break;
      case 'openSendTabFromTray':
        await onOpenSendTabFromTray?.call();
        break;
    }
  });

  await _methodChannel.invokeMethod('methodChannelInitialized');
}
