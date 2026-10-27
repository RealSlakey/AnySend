// Drives the open source Tailscale daemon (`tailscaled`) that AnySend installs
// as a root LaunchDaemon. Running the daemon outside of an app sandbox means it
// can create a real `utun` interface, so the whole Mac joins the tailnet: every
// port, ICMP and UDP traffic is reachable from other tailnet nodes.
//
// The app itself never runs as root. Installation is a one-off administrator
// prompt; afterwards the bundled `tailscale` CLI talks to the daemon over a
// world-writable LocalAPI socket on behalf of the logged-in user.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/macos_channel.dart';

class TailscaleException implements Exception {
  final String message;

  const TailscaleException(this.message);

  @override
  String toString() => message;
}

/// Snapshot of the daemon state, adapted from `tailscale status --json`.
class TailscaleStatus {
  /// `Running`, `Stopped`, `NeedsLogin`, `NeedsMachineAuth`, `Starting`…
  final String backendState;
  final String? hostName;
  final String? ipv4;
  final String? ipv6;

  const TailscaleStatus({
    required this.backendState,
    this.hostName,
    this.ipv4,
    this.ipv6,
  });

  bool get running => backendState == 'Running';

  bool get needsLogin => backendState == 'NeedsLogin';

  static const TailscaleStatus unavailable = TailscaleStatus(backendState: 'Unavailable');
}

/// One other node in the tailnet (`tailscale status --json` → Peer).
class TailnetPeer {
  const TailnetPeer({
    required this.hostName,
    required this.ip,
    required this.os,
    required this.online,
  });

  final String hostName;
  final String ip;

  /// `macOS`, `windows`, `android`, `linux`, `iOS`…
  final String os;
  final bool online;

  bool get isAndroid => os.toLowerCase() == 'android';
}

class TailscaleService {
  static const String installDir = '/Library/Application Support/AnySend';

  static const String socketPath = '$installDir/tailscaled.sock';

  static const String daemonPath = '$installDir/tailscaled';

  static const String cliPath = '$installDir/tailscale';

  static Future<bool> isInstalled() async {
    return File(daemonPath).existsSync();
  }

  /// True when the daemon is not only installed but also answering.
  static Future<bool> isDaemonRunning() async {
    return Socket.connect(socketPath, 0, timeout: const Duration(milliseconds: 300))
        .then((socket) {
      socket.destroy();
      return true;
    }).catchError((_) => false);
  }

  static Future<TailscaleStatus> status() async {
    final result = await _runCli(['status', '--json']);
    if (result.exitCode != 0) {
      return TailscaleStatus.unavailable;
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map) {
      return TailscaleStatus.unavailable;
    }
    final self = decoded['Self'];
    final ips = self is Map ? self['TailscaleIPs'] : null;
    String? ipv4;
    String? ipv6;
    if (ips is List) {
      for (final ip in ips) {
        if (ip is! String) continue;
        if (ip.contains(':') && ipv6 == null) ipv6 = ip;
        if (!ip.contains(':') && ipv4 == null) ipv4 = ip;
      }
    }
    return TailscaleStatus(
      backendState: (decoded['BackendState'] as String?) ?? 'Unknown',
      hostName: self is Map ? self['HostName'] as String? : null,
      ipv4: ipv4,
      ipv6: ipv6,
    );
  }

  /// Connects to the tailnet. Returns once `tailscale up` exits.
  ///
  /// Without an auth key the CLI prints a login URL; it is forwarded to
  /// [onAuthUrl] so the caller can open the browser.
  static Future<void> up({String? authKey, String? hostname, void Function(String url)? onAuthUrl}) async {
    final args = <String>['up'];
    if (hostname != null && hostname.isNotEmpty) {
      args.add('--hostname=$hostname');
    }
    if (authKey != null && authKey.trim().isNotEmpty) {
      args.add('--auth-key=${authKey.trim()}');
      args.add('--timeout=45s');
    }
    final process = await Process.start(cliPath, ['--socket=$socketPath', ...args]);

    final output = StringBuffer();
    var authUrlSeen = false;
    void consume(String chunk) {
      output.write(chunk);
      if (authUrlSeen) return;
      final match = RegExp(r'https://login\.tailscale\.com/\S+').firstMatch(output.toString());
      if (match != null) {
        authUrlSeen = true;
        onAuthUrl?.call(match.group(0)!);
      }
    }

    process.stdout.transform(utf8.decoder).listen(consume);
    process.stderr.transform(utf8.decoder).listen(consume);

    final code = await process.exitCode;
    if (code != 0) {
      throw TailscaleException(output.toString().trim().isEmpty ? 'tailscale up 失败（退出码 $code）' : output.toString().trim());
    }
  }

  static Future<void> down() async {
    final result = await _runCli(['down']);
    if (result.exitCode != 0) {
      throw TailscaleException(_describeFailure(result));
    }
  }

  static Future<void> logout() async {
    final result = await _runCli(['logout']);
    if (result.exitCode != 0) {
      throw TailscaleException(_describeFailure(result));
    }
  }

  /// Renames this node in the tailnet without re-running a full login.
  static Future<void> setHostname(String hostname) async {
    final result = await _runCli(['set', '--hostname=$hostname']);
    if (result.exitCode != 0) {
      throw TailscaleException(_describeFailure(result));
    }
  }

  /// Tailscale only accepts `[a-z0-9-]`, so the user-facing device name has to
  /// be folded into that alphabet.
  static String sanitizeHostname(String raw) {
    final buffer = StringBuffer();
    var lastWasDash = false;
    for (final rune in raw.toLowerCase().runes) {
      final isAlnum = (rune >= 0x61 && rune <= 0x7a) || (rune >= 0x30 && rune <= 0x39);
      if (isAlnum) {
        buffer.writeCharCode(rune);
        lastWasDash = false;
      } else if (!lastWasDash && buffer.isNotEmpty) {
        buffer.write('-');
        lastWasDash = true;
      }
    }
    var result = buffer.toString();
    if (result.length > 63) {
      result = result.substring(0, 63);
    }
    while (result.endsWith('-')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  /// Derives the tailnet node name from the app's device name.
  ///
  /// Non-ASCII device names (e.g. Chinese) are transliterated instead of being
  /// dropped, so both ends of AnySend still show comparable names.
  static Future<String> deriveHostname(String deviceName) async {
    final direct = sanitizeHostname(deviceName);
    if (direct.isNotEmpty) {
      return direct;
    }
    try {
      final latin = sanitizeHostname(await transliterateToLatin(deviceName));
      if (latin.isNotEmpty) {
        return latin;
      }
    } catch (_) {
      // The native transliterator is unavailable; fall through to the default.
    }
    return 'anysend-mac';
  }

  /// Installs the bundled daemon as a root LaunchDaemon. Shows one
  /// administrator prompt; there is no password-less path for launchd.
  static Future<void> install() async {
    final srcDir = await _extractAssets();
    try {
      await _runAsAdmin(
        script: '$srcDir/install.sh',
        args: [srcDir, Platform.environment['USER'] ?? ''],
        prompt: 'AnySend 需要管理员权限，把 Tailscale 后台服务安装到系统',
      );
    } finally {
      await _cleanup(srcDir);
    }
  }

  static Future<void> uninstall() async {
    final srcDir = await _extractAssets();
    try {
      await _runAsAdmin(
        script: '$srcDir/uninstall.sh',
        args: [srcDir],
        prompt: 'AnySend 需要管理员权限，移除 Tailscale 后台服务',
      );
    } finally {
      await _cleanup(srcDir);
    }
  }

  /// Peers in the tailnet, used to find Android devices without typing an IP.
  ///
  /// Mirrors the HarmonyOS side, which lists every android peer's tailnet
  /// address and probes them for `/api/anysend/v1/...`.
  static Future<List<TailnetPeer>> peers() async {
    final result = await _runCli(['status', '--json']);
    if (result.exitCode != 0) {
      return const [];
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map) {
      return const [];
    }
    final raw = decoded['Peer'];
    if (raw is! Map) {
      return const [];
    }
    final peers = <TailnetPeer>[];
    for (final entry in raw.values) {
      if (entry is! Map) continue;
      final ips = entry['TailscaleIPs'];
      String? ipv4;
      if (ips is List) {
        for (final ip in ips) {
          if (ip is String && !ip.contains(':')) {
            ipv4 = ip;
            break;
          }
        }
      }
      if (ipv4 == null) continue;
      peers.add(TailnetPeer(
        hostName: (entry['HostName'] as String?) ?? ipv4,
        ip: ipv4,
        os: (entry['OS'] as String?) ?? '',
        online: entry['Online'] as bool? ?? false,
      ));
    }
    return peers;
  }

  static Future<ProcessResult> _runCli(List<String> args) async {
    if (!await isInstalled()) {
      return ProcessResult(0, -1, '', 'tailscale 未安装');
    }
    return Process.run(cliPath, ['--socket=$socketPath', ...args]);
  }

  static String _describeFailure(ProcessResult result) {
    final message = (result.stderr as String).trim();
    return message.isEmpty ? '命令执行失败（退出码 ${result.exitCode}）' : message;
  }

  static Future<String> _extractAssets() async {
    final dir = await Directory.systemTemp.createTemp('anysend_ts_');
    for (final name in ['tailscaled', 'tailscale', 'install.sh', 'uninstall.sh']) {
      final data = await rootBundle.load('assets/tailscaled/$name');
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
    }
    final chmod = await Process.run('chmod', ['755', '${dir.path}/tailscaled', '${dir.path}/tailscale', '${dir.path}/install.sh', '${dir.path}/uninstall.sh']);
    if (chmod.exitCode != 0) {
      throw TailscaleException('无法为解压后的二进制设置执行权限');
    }
    return dir.path;
  }

  static Future<void> _cleanup(String dir) async {
    try {
      await Directory(dir).delete(recursive: true);
    } catch (_) {
      // Temporary directory; leaving it behind is harmless.
    }
  }

  static Future<void> _runAsAdmin({
    required String script,
    required List<String> args,
    required String prompt,
  }) async {
    final command = ['/bin/sh', script, ...args].map(_shellQuote).join(' ');
    final appleScript = 'do shell script ${_appleScriptString(command)} with administrator privileges with prompt ${_appleScriptString(prompt)}';
    final result = await Process.run('/usr/bin/osascript', ['-e', appleScript]);
    if (result.exitCode != 0) {
      throw TailscaleException((result.stderr as String).trim());
    }
  }

  /// POSIX single-quote escaping: everything between quotes is literal.
  static String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static String _appleScriptString(String value) => '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}
