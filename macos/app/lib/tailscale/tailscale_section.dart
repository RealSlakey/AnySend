// Settings widget for the embedded Tailscale daemon.
//
// Placed inside the Settings tab card. Everything here talks to [TailscaleService];
// no other widget should talk to the daemon directly.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/tailscale/tailscale_service.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class TailscaleSection extends StatefulWidget {
  const TailscaleSection({super.key});

  @override
  State<TailscaleSection> createState() => _TailscaleSectionState();
}

class _TailscaleSectionState extends State<TailscaleSection> {
  final TextEditingController _authKeyController = TextEditingController();

  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  TailscaleStatus? _status;
  String? _error;
  Timer? _poll;

  /// Last node name pushed to the daemon, so the poll loop does not rename the
  /// node over and over when the tailnet refuses the change.
  String? _appliedHostname;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_busy) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _authKeyController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final installed = await TailscaleService.isInstalled();
    TailscaleStatus? status;
    if (installed) {
      status = await TailscaleService.status();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _installed = installed;
      _status = status;
    });
    if (status != null && status.running) {
      await _syncHostname(status);
    }
  }

  /// Keeps the tailnet node name equal to the app's device name, so the same
  /// machine does not show up under two different names.
  Future<void> _syncHostname(TailscaleStatus status) async {
    if (!mounted) return;
    final desired = await TailscaleService.deriveHostname(context.read(settingsProvider).alias);
    if (desired == status.hostName || desired == _appliedHostname) return;
    _appliedHostname = desired;
    try {
      await TailscaleService.setHostname(desired);
      await _refresh();
    } catch (_) {
      // Renaming is cosmetic; a rejected name should not surface as an error.
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _install() => _guard(TailscaleService.install);

  Future<void> _uninstall() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除 Tailscale 服务'),
        content: const Text('会停止后台服务并删除节点状态，下次使用需要重新登录。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('移除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _guard(TailscaleService.uninstall);
  }

  Future<void> _connect({String? authKey}) async {
    final hostname = await TailscaleService.deriveHostname(context.read(settingsProvider).alias);
    await _guard(() async {
      await TailscaleService.up(
        authKey: authKey,
        hostname: hostname,
        onAuthUrl: (url) async {
          if (url.isNotEmpty) {
            await launchUrl(Uri.parse(url));
          }
        },
      );
    });
  }

  Future<void> _disconnect() => _guard(TailscaleService.down);

  Future<void> _logout() => _guard(TailscaleService.logout);

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制监听 IP')));
  }

  String get _stateLabel {
    final status = _status;
    if (status == null || status.backendState == 'Unavailable') return '服务未运行';
    switch (status.backendState) {
      case 'Running':
        return '已加入 tailnet';
      case 'NeedsLogin':
        return '需要登录';
      case 'Stopped':
        return '已停止';
      default:
        return status.backendState;
    }
  }

  Color _stateColor(BuildContext context) {
    final status = _status;
    if (status?.running == true) return Colors.green;
    if (status?.needsLogin == true) return Colors.orange;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }

    if (!_installed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '把开源 tailscaled 作为系统后台服务安装后，这台 Mac 会以一个真实节点加入 tailnet：'
            '其它设备可以按 100.x 地址访问它的任意端口、ICMP 和 UDP，而不是只能访问固定端口。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            '安装需要一次管理员授权。应用本身以普通用户运行。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _install,
            icon: const Icon(Icons.lan_outlined, size: 18),
            label: Text(_busy ? '安装中…' : '安装并启用'),
          ),
          if (_error != null) _buildError(theme),
        ],
      );
    }

    final status = _status ?? TailscaleStatus.unavailable;
    final ip = status.ipv4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: _stateColor(context)),
            const SizedBox(width: 8),
            Text(_stateLabel, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(status.hostName ?? '', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        if (ip != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Text(ip, style: theme.textTheme.bodyMedium),
              const SizedBox(width: 6),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () => _copy(ip),
                icon: const Icon(Icons.copy_all_outlined),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Text(
          '节点名自动跟随「设备名称」。Tailscale 只接受英文、数字和连字符，中文名会转成拼音。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!status.running)
              FilledButton(
                onPressed: _busy ? null : () => _connect(),
                child: const Text('连接'),
              ),
            if (status.running)
              OutlinedButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('断开'),
              ),
            OutlinedButton(
              onPressed: _busy ? null : _logout,
              child: const Text('注销节点'),
            ),
            TextButton(
              onPressed: _busy ? null : _uninstall,
              child: const Text('移除服务'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '登录密钥（可选）：在管理后台生成 auth key 后粘贴，无需在浏览器里操作。',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _authKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'tskey-…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _busy
                  ? null
                  : () => _connect(authKey: _authKeyController.text).then((_) {
                        _authKeyController.clear();
                      }),
              child: const Text('用密钥连接'),
            ),
          ],
        ),
        if (_error != null) _buildError(theme),
      ],
    );
  }

  Widget _buildError(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        _error!,
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ),
    );
  }
}
