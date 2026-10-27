// Mac controlling end for Android devices — the desktop counterpart of the
// HarmonyOS 屏幕镜像 / 应用推流 pages.
//
// Two entries sit side by side, exactly like the phone app:
//   应用推流 — pick one Android app, it runs on a fresh virtual display on the
//             phone and is streamed here; the phone's own screen stays as it is;
//   屏幕镜像 — stream the phone's whole screen.
//
// The streaming itself happens in `AndroidMirrorController`: scrcpy-server over
// TCP, H.264 decoded into an AVSampleBufferDisplayLayer. This widget only drives
// it and shows the app inventory.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/remote/android_mirror_service.dart';
import 'package:localsend_app/tailscale/tailscale_service.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AndroidMirrorSection extends StatefulWidget {
  const AndroidMirrorSection({super.key});

  @override
  State<AndroidMirrorSection> createState() => _AndroidMirrorSectionState();
}

class _AndroidMirrorSectionState extends State<AndroidMirrorSection> {
  static const _keyHost = 'anysend_android_mirror_host';

  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  AndroidMirrorStatus _status = AndroidMirrorStatus.empty;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// 应用推流：宫格是否展开，以及清单状态。
  bool _appsOpen = false;
  bool _appsLoading = false;
  String _appsNote = '';
  String _appsQuery = '';
  String? _launchNote;
  List<AndroidAppEntry> _apps = const [];

  /// 安卓 tailnet 节点：与鸿蒙端一样自动找设备，不用手输 100.x 地址。
  List<TailnetPeer> _androidPeers = const [];

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    AndroidMirrorService.setErrorListener((message) {
      if (!mounted) return;
      setState(() => _error = message);
    });
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_busy) unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    AndroidMirrorService.setErrorListener(null);
    _hostController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _hostController.text = prefs.getString(_keyHost) ?? '';
    await _refreshStatus();
    if (!mounted) return;
    setState(() => _loading = false);
    // 先读回上次的地址再自动选设备，避免把已保存的地址覆盖掉。
    await _refreshPeers();
  }

  /// Lists android nodes in the tailnet and pre-selects one when the address
  /// field is still empty — the desktop equivalent of the phone app picking
  /// the android peer automatically.
  Future<void> _refreshPeers() async {
    List<TailnetPeer> peers;
    try {
      peers = await TailscaleService.peers();
    } catch (_) {
      peers = const [];
    }
    final androidPeers = peers.where((p) => p.isAndroid && p.online).toList();
    if (!mounted) return;
    final auto = _hostController.text.trim().isEmpty && androidPeers.length == 1;
    setState(() {
      _androidPeers = androidPeers;
      if (auto) {
        _hostController.text = androidPeers.first.ip;
      }
    });
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await AndroidMirrorService.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        // 原生侧异步失败（握手、安卓端断开）也要显示出来，否则用户只看到「没反应」。
        if (status.error != null) {
          _error = status.error;
        } else if (status.active) {
          _error = null;
        }
        if (!status.active) _launchNote = null;
      });
    } catch (_) {
      // A native call failing here only means the status is unavailable.
    }
  }

  Future<String?> _requireHost() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      if (mounted) setState(() => _error = '请先选择或输入安卓设备地址');
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHost, host);
    return host;
  }

  Future<void> _startMirror() async {
    final host = await _requireHost();
    if (host == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _appsOpen = false;
    });
    try {
      await AndroidMirrorService.start(host);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  Future<void> _openApps() async {
    final host = await _requireHost();
    if (host == null) return;
    setState(() {
      _appsOpen = true;
      _error = null;
    });
    await _loadApps(host: host);
  }

  Future<void> _loadApps({String? host, bool refresh = false}) async {
    final target = host ?? _hostController.text.trim();
    if (target.isEmpty) {
      setState(() => _error = '请先选择或输入安卓设备地址');
      return;
    }
    setState(() {
      _appsLoading = true;
      _appsNote = '正在读取安卓端应用列表…';
    });
    try {
      final list = await AndroidMirrorService.fetchApps(target, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _apps = list;
        _appsLoading = false;
        _appsNote = list.isEmpty ? '没能读取到安卓端应用列表，请确认两端 AnySend 都在运行、Tailscale 已连接' : '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _apps = const [];
        _appsLoading = false;
        _appsNote = '读取应用列表失败：$e';
      });
    }
  }

  Future<void> _startApp(AndroidAppEntry app) async {
    final host = await _requireHost();
    if (host == null) return;
    final label = app.label.isEmpty ? app.pkg : app.label;
    setState(() {
      _busy = true;
      _error = null;
      _launchNote = '正在启动「$label」…';
    });
    try {
      await AndroidMirrorService.startApp(host, app);
      // 原生窗口会盖上来，这里留一条状态，万一失败也能看到原因。
      if (mounted) setState(() => _launchNote = '已请求推流「$label」，若窗口未出现请查看下方错误信息');
    } catch (e) {
      if (mounted) {
        setState(() {
          _launchNote = null;
          _error = '启动应用失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await AndroidMirrorService.stop();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshStatus();
    }
  }

  String get _stateLabel {
    if (!_status.active) return '未连接';
    final size = _status.width > 0 ? ' · ${_status.width}×${_status.height}' : '';
    final mode = _status.appStreaming ? '应用推流' : '屏幕镜像';
    return '$mode中 · ${_status.name}$size';
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

    // Discovered LocalSend peers that expose an IP can be mirrored directly;
    // android nodes from the tailnet cover the cross-network case, exactly like
    // the phone app which only knows tailnet peers.
    final devices = context
        .ref
        .watch(nearbyDevicesProvider)
        .devices
        .values
        .where((d) => d.ip != null && d.ip!.isNotEmpty)
        .toList();
    final options = <String, String>{
      for (final d in devices) d.ip!: '${d.alias} · ${d.ip}',
      for (final p in _androidPeers) p.ip: '${p.hostName} · 安卓 · ${p.ip}',
    };
    final selectable = options.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: _status.active ? Colors.green : theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(child: Text(_stateLabel, style: theme.textTheme.bodyMedium)),
            if (_status.active)
              TextButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('断开'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (selectable.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('android-mirror-devices-${selectable.length}'),
            initialValue: selectable.contains(_hostController.text.trim()) ? _hostController.text.trim() : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '选择安卓设备', isDense: true),
            items: selectable
                .map((ip) => DropdownMenuItem(value: ip, child: Text(options[ip]!, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() => _hostController.text = value);
                  },
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _hostController,
          decoration: const InputDecoration(
            labelText: '安卓设备地址',
            hintText: 'Tailscale 100.x 或局域网 IP',
            isDense: true,
          ),
          onSubmitted: (_) => _busy ? null : _startMirror(),
        ),
        const SizedBox(height: 14),
        // 两个入口左右并排，与鸿蒙端 TransferPage 完全一致：左=应用推流，右=屏幕镜像。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _EntryTile(
                icon: Icons.tab_unselected,
                title: '应用推流',
                subtitle: '把单个安卓应用推到本机运行',
                highlighted: _appsOpen,
                onTap: _busy ? null : _openApps,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _EntryTile(
                icon: Icons.monitor,
                title: '屏幕镜像',
                subtitle: '实时查看安卓手机屏幕',
                highlighted: _status.active && !_status.appStreaming,
                onTap: _busy ? null : _startMirror,
              ),
            ),
          ],
        ),
        if (_appsOpen) ...[
          const SizedBox(height: 16),
          _appsHeader(theme),
          const SizedBox(height: 8),
          // 点选应用后的结果（成功/失败）就显示在宫格上方，不用往下翻。
          if (_error != null) ...[
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
          ],
          _appsBody(theme, hint),
        ],
        const SizedBox(height: 10),
        Text(
          '安卓端需保持 AnySend 在前台并已授予 Shizuku 权限。应用推流会在安卓端新建虚拟显示，'
          '只把这一个应用推过来，手机自己的屏幕不受影响。',
          style: hint,
        ),
        if (_busy) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(),
        ],
        if (!_appsOpen && _error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
      ],
    );
  }

  Widget _appsHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('选择要推流的应用', style: theme.textTheme.titleSmall),
            ),
            IconButton(
              tooltip: '刷新应用列表',
              onPressed: _appsLoading ? null : () => _loadApps(refresh: true),
              icon: const Icon(Icons.refresh, size: 18),
            ),
            TextButton(
              onPressed: () => setState(() => _appsOpen = false),
              child: const Text('收起'),
            ),
          ],
        ),
        // 应用多的时候靠搜索定位，比翻宫格快得多。
        SizedBox(
          height: 34,
          child: TextField(
            controller: _searchController,
            style: theme.textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索应用',
              prefixIcon: const Icon(Icons.search, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              suffixIcon: _appsQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _appsQuery = '');
                      },
                    ),
              suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: (value) => setState(() => _appsQuery = value.trim()),
          ),
        ),
      ],
    );
  }

  /// 按名称 / 包名过滤，空查询时返回原清单。
  List<AndroidAppEntry> get _visibleApps {
    if (_appsQuery.isEmpty) return _apps;
    final query = _appsQuery.toLowerCase();
    return _apps
        .where((app) => app.label.toLowerCase().contains(query) || app.pkg.toLowerCase().contains(query))
        .toList();
  }

  Widget _appsBody(ThemeData theme, TextStyle? hint) {
    if (_launchNote != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(_launchNote!, style: hint)),
          ],
        ),
      );
    }
    if (_appsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 12),
            Text(_appsNote, style: hint, textAlign: TextAlign.center),
          ],
        ),
      );
    }
    if (_apps.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_appsNote.isEmpty ? '没有可推流的应用' : _appsNote, style: hint),
          const SizedBox(height: 8),
          TextButton(onPressed: () => _loadApps(), child: const Text('重新读取')),
        ],
      );
    }
    final apps = _visibleApps;
    if (apps.isEmpty) {
      return Text('没有匹配「$_appsQuery」的应用', style: hint);
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      // 紧凑宫格：一行 6 个，图标 32，应用多时也能一屏看完。
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 0.82,
      ),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _AppCell(
          app: app,
          enabled: !_busy,
          onTap: () => _startApp(app),
        );
      },
    );
  }
}

/// Tile used for the 应用推流 / 屏幕镜像 entries.
class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlighted ? scheme.primary : scheme.outlineVariant,
            width: highlighted ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: scheme.primary),
            const SizedBox(height: 8),
            Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// One app in the 应用推流 grid: icon (or a placeholder) above the label.
class _AppCell extends StatelessWidget {
  const _AppCell({required this.app, required this.enabled, required this.onTap});

  final AndroidAppEntry app;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: app.icon == null
                  ? Container(
                      width: 32,
                      height: 32,
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.apps, size: 18, color: scheme.onSurfaceVariant),
                    )
                  : Image.memory(app.icon!, width: 32, height: 32, fit: BoxFit.contain),
            ),
            const SizedBox(height: 4),
            Text(
              app.label.isEmpty ? app.pkg : app.label,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}