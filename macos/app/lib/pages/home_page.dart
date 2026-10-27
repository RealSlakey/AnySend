import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/selected_files_page.dart';
import 'package:localsend_app/pages/tabs/receive_tab.dart';
import 'package:localsend_app/pages/tabs/remote_tab.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

enum HomeTab {
  receive(Icons.wifi),
  send(Icons.send),
  remote(Icons.screen_share),
  settings(Icons.settings)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.receive:
        return t.receiveTab.title;
      case HomeTab.send:
        return t.sendTab.title;
      case HomeTab.remote:
        return '远控';
      case HomeTab.settings:
        return t.settingsTab.title;
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;

  /// Native side registers the system-wide ⌘⇧V hotkey and pings this channel,
  /// so the text can be read (and edited) with the normal Flutter flow instead
  /// of duplicating the clipboard logic in Swift.
  static const _hotKeyChannel = MethodChannel('anysend/hotkey');

  @override
  void initState() {
    super.initState();

    _hotKeyChannel.setMethodCallHandler((call) async {
      if (call.method == 'sendClipboard') {
        await _sendClipboardText();
      }
      return null;
    });

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  Future<void> _sendClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) {
      return;
    }
    if (text == null || text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板里没有文字')));
      return;
    }

    ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: text));
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
    await context.push(() => const SelectedFilesPage());
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);

    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _dragAndDropIndicator = true;
        });
      },
      onDragExited: (_) {
        setState(() {
          _dragAndDropIndicator = false;
        });
      },
      onDragDone: (event) async {
        // the drop may contain a mix of files and directories
        final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
        final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

        for (final directory in droppedDirectories) {
          await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
        }

        if (droppedFiles.isNotEmpty) {
          await ref
              .redux(selectedSendingFilesProvider)
              .dispatchAsync(
                AddFilesAction(
                  files: droppedFiles,
                  converter: CrossFileConverters.convertXFile,
                ),
              );
        }
        vm.changeTab(HomeTab.send);
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                      ),
                    ),
                    child: NavigationRail(
                      selectedIndex: vm.currentTab.index,
                      onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                      extended: sizingInformation.isDesktop,
                      backgroundColor: Theme.of(context).colorScheme.surface,
                      leading: sizingInformation.isDesktop
                          ? Column(
                              children: [
                                const SizedBox(height: 18),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(width: 12),
                                    Assets.img.logo32.image(width: 26, height: 26),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'AnySend',
                                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.2),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                              ],
                            )
                          : Padding(
                              padding: const EdgeInsets.only(top: 18, bottom: 14),
                              child: Assets.img.logo32.image(width: 24, height: 24),
                            ),
                      destinations: HomeTab.values.map((tab) {
                        return NavigationRailDestination(
                          icon: Icon(tab.icon),
                          label: Text(tab.label),
                        );
                      }).toList(),
                    ),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            ReceiveTab(),
                            SendTab(),
                            RemoteTab(),
                            SettingsTab(),
                          ],
                        ),
                        if (_dragAndDropIndicator)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.file_download, size: 128),
                                const SizedBox(height: 30),
                                Text(t.sendTab.placeItems, style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: sizingInformation.isMobile
                ? NavigationBar(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    destinations: HomeTab.values.map((tab) {
                      return NavigationDestination(icon: Icon(tab.icon), label: tab.label);
                    }).toList(),
                  )
                : null,
          );
        },
      ),
    );
  }
}
