// 一级「远控」页 —— 与「接收 / 发送」平级的独立入口。
//
// 远控是常用功能，不该埋在设置里：上半部分是这台 Mac 控制安卓（应用推流 /
// 屏幕镜像），下半部分是这台 Mac 作为被控端被手机远控。设置页只保留纯配置项。

import 'package:flutter/material.dart';
import 'package:localsend_app/remote/android_mirror_section.dart';
import 'package:localsend_app/remote/remote_host_section.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';

class RemoteTab extends StatelessWidget {
  const RemoteTab();

  @override
  Widget build(BuildContext context) {
    return ResponsiveListView(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 40),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text('远控', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 30),
        _RemoteSection(
          title: '控制安卓设备',
          description: '把安卓手机的画面、或单个应用投到这台 Mac，用鼠标和键盘直接操作。',
          children: const [AndroidMirrorSection()],
        ),
        _RemoteSection(
          title: '被控端（这台 Mac）',
          description: '手机端打开远控后连接这台 Mac 的 27042 / 27043 端口。',
          children: const [RemoteHostSection()],
        ),
      ],
    );
  }
}

class _RemoteSection extends StatelessWidget {
  final String title;
  final String description;
  final List<Widget> children;

  const _RemoteSection({
    required this.title,
    required this.description,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}
