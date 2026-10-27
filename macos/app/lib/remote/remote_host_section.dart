// Settings widget for the Mac controlled end (remote desktop host).
//
// The host pushes H.264 video on port 27042 and accepts scrcpy control
// messages on port 27043, so the mobile clients reuse their existing pipeline.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/remote/remote_host_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RemoteHostSection extends StatefulWidget {
  const RemoteHostSection({super.key});

  @override
  State<RemoteHostSection> createState() => _RemoteHostSectionState();
}

class _RemoteHostSectionState extends State<RemoteHostSection> {
  static const _keyEnabled = RemoteHostService.keyEnabled;
  static const _keyPin = RemoteHostService.keyPin;
  static const _keyMaxWidth = RemoteHostService.keyMaxWidth;
  static const _keyFps = RemoteHostService.keyFps;
  static const _keyBitrate = RemoteHostService.keyBitrate;
  static const _keyClipboard = RemoteHostService.keyClipboard;

  final TextEditingController _pinController = TextEditingController();

  SharedPreferences? _prefs;
  RemoteHostStatus _status = RemoteHostStatus.empty;
  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;
  bool _clipboard = true;
  int _maxWidth = 1920;
  int _fps = 25;
  int _bitrate = 8;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_busy) unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _enabled = prefs.getBool(_keyEnabled) ?? false;
      _pinController.text = prefs.getString(_keyPin) ?? '';
      _maxWidth = prefs.getInt(_keyMaxWidth) ?? 1920;
      _fps = prefs.getInt(_keyFps) ?? 25;
      _bitrate = prefs.getInt(_keyBitrate) ?? 8;
      _clipboard = prefs.getBool(_keyClipboard) ?? true;
    });
    await _refreshStatus();
    if (!mounted) return;
    setState(() => _loading = false);
    // Restart the host automatically when it was left enabled.
    if (_enabled && !_status.running) {
      await _start();
    }
  }

  Future<void> _refreshStatus() async {
    final status = await RemoteHostService.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    await prefs.setBool(_keyEnabled, _enabled);
    await prefs.setString(_keyPin, _pinController.text.trim());
    await prefs.setInt(_keyMaxWidth, _maxWidth);
    await prefs.setInt(_keyFps, _fps);
    await prefs.setInt(_keyBitrate, _bitrate);
    await prefs.setBool(_keyClipboard, _clipboard);
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await RemoteHostService.start(
        pin: _pinController.text.trim(),
        maxWidth: _maxWidth,
        fps: _fps,
        bitrateMbps: _bitrate,
        clipboard: _clipboard,
      );
    } catch (e) {
      if (mounted) setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await RemoteHostService.stop();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await _save();
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _applyQuality() async {
    await _save();
    if (_status.running) {
      await _stop();
      await _start();
    }
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('screen_permission_missing')) {
      return '缺少屏幕录制权限，请在系统设置中授权后重试。';
    }
    return text;
  }

  Color _stateColor(BuildContext context) {
    if (_status.hasClient) return Colors.green;
    if (_status.running) return Colors.lightGreen;
    if ((_status.lastError ?? '').isNotEmpty) return Colors.orange;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  /// Capture-side failures are the only ones that are caused by a missing TCC
  /// permission; everything else (typically a port already in use) must not
  /// offer the “去授权” button.
  static bool _isCaptureError(String? error) {
    if (error == null || error.isEmpty) return false;
    return error.contains('shareable_content') ||
        error.contains('start_capture') ||
        error.contains('add_stream_output') ||
        error.contains('no_display');
  }

  String get _stateLabel {
    if (_status.hasClient) return '已连接 1 台设备';
    if (_status.running) return '等待连接';
    final error = _status.lastError ?? '';
    if (error.isNotEmpty) return '启动失败：$error';
    return '未开启';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: _stateColor(context)),
            const SizedBox(width: 8),
            // The label carries the whole native error text, which can be far
            // wider than the card; let it ellipsise instead of overflowing.
            Expanded(
              child: Text(
                _stateLabel,
                style: theme.textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Switch(
              value: _enabled,
              onChanged: _busy ? null : _toggle,
            ),
          ],
        ),
        if (_status.running) ...[
          const SizedBox(height: 4),
          Text(
            '画面 ${_status.width}×${_status.height} · ${_status.fps}fps · '
            '视频 ${RemoteHostService.videoPort} / 控制 ${RemoteHostService.controlPort}',
            style: hint,
          ),
        ],
        const SizedBox(height: 10),

        // The screen-recording preflight API reports false even for apps TCC has
        // already authorised, so the capture error reported by the native side
        // is the only reliable signal that permission is actually missing.
        // Only capture failures get this hint: a port conflict is already shown
        // in the state line above and has nothing to do with permissions.
        if (_isCaptureError(_status.lastError))
          _permissionRow(
            theme: theme,
            title: '屏幕采集失败（若为权限问题请重新授权后重启应用）',
            actionLabel: '去授权',
            onTap: () async {
              await RemoteHostService.requestScreenPermission();
              await _refreshStatus();
            },
          ),
        if (!_status.accessibilityPermission)
          _permissionRow(
            theme: theme,
            title: '辅助功能权限未授权（无法注入键鼠）',
            actionLabel: '打开设置',
            onTap: () async {
              await RemoteHostService.openAccessibilitySettings();
            },
          ),

        const SizedBox(height: 10),
        TextField(
          controller: _pinController,
          decoration: const InputDecoration(
            labelText: '访问 PIN',
            hintText: '留空则不校验',
            isDense: true,
          ),
          onSubmitted: (_) => _applyQuality(),
        ),
        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey('maxWidth-$_maxWidth'),
                initialValue: _maxWidth,
                decoration: const InputDecoration(labelText: '画面上限', isDense: true),
                items: const [
                  DropdownMenuItem(value: 1280, child: Text('1280 宽')),
                  DropdownMenuItem(value: 1600, child: Text('1600 宽')),
                  DropdownMenuItem(value: 1920, child: Text('1920 宽')),
                  DropdownMenuItem(value: 2560, child: Text('2560 宽')),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _maxWidth = value);
                        unawaited(_applyQuality());
                      },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey('fps-$_fps'),
                initialValue: _fps,
                decoration: const InputDecoration(labelText: '帧率', isDense: true),
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 fps')),
                  DropdownMenuItem(value: 25, child: Text('25 fps')),
                  DropdownMenuItem(value: 30, child: Text('30 fps')),
                  DropdownMenuItem(value: 60, child: Text('60 fps')),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _fps = value);
                        unawaited(_applyQuality());
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey('bitrate-$_bitrate'),
                initialValue: _bitrate,
                decoration: const InputDecoration(labelText: '码率', isDense: true),
                items: const [
                  DropdownMenuItem(value: 4, child: Text('4 Mbps')),
                  DropdownMenuItem(value: 8, child: Text('8 Mbps')),
                  DropdownMenuItem(value: 12, child: Text('12 Mbps')),
                  DropdownMenuItem(value: 20, child: Text('20 Mbps')),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _bitrate = value);
                        unawaited(_applyQuality());
                      },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  const Expanded(child: Text('同步剪贴板')),
                  Switch(
                    value: _clipboard,
                    onChanged: _busy
                        ? null
                        : (value) {
                            setState(() => _clipboard = value);
                            unawaited(_applyQuality());
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '移动端按 H.264 直连这两个端口即可投屏并反向控制。建议只在 Tailscale 网络内开启；'
          '设置 PIN 后，连接时需先发送 PIN 才能拉流。',
          style: hint,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _permissionRow({
    required ThemeData theme,
    required String title,
    required String actionLabel,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title, style: theme.textTheme.bodySmall),
          ),
          TextButton(onPressed: onTap, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
