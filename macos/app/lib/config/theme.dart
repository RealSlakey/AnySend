import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:yaru/yaru.dart' as yaru;

final _borderRadius = BorderRadius.circular(12);

/// Brand plate shared with the Android and HarmonyOS clients.
const _brandPrimary = Color(0xFF0A59F1);

/// The AnySend palette, mirrored from `android/.../values/colors.xml` and the
/// HarmonyOS `DesignTokens` so all three clients read as one product.
ColorScheme _anySendColorScheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(seedColor: _brandPrimary, brightness: brightness);
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: _brandPrimary,
      onPrimary: const Color(0xFFFFFFFF),
      primaryContainer: const Color(0xFFD8E2FF),
      onPrimaryContainer: const Color(0xFF001945),
      surface: const Color(0xFFF8F9FC),
      onSurface: const Color(0xFF191C20),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFF8F9FC),
      surfaceContainer: const Color(0xFFF1F3F8),
      surfaceContainerHigh: const Color(0xFFEBEEF5),
      surfaceContainerHighest: const Color(0xFFE0E2EC),
      onSurfaceVariant: const Color(0xFF43474E),
      outline: const Color(0xFF73777F),
      outlineVariant: const Color(0xFFC3C6CF),
    );
  }
  return base.copyWith(
    primary: const Color(0xFFADC2FF),
    onPrimary: const Color(0xFF002D6F),
    primaryContainer: const Color(0xFF00449E),
    onPrimaryContainer: const Color(0xFFD8E2FF),
    surface: const Color(0xFF111318),
    onSurface: const Color(0xFFE2E2E9),
    surfaceContainerLowest: const Color(0xFF0B0D11),
    surfaceContainerLow: const Color(0xFF16181D),
    surfaceContainer: const Color(0xFF1D2026),
    surfaceContainerHigh: const Color(0xFF24272E),
    surfaceContainerHighest: const Color(0xFF2C3037),
    onSurfaceVariant: const Color(0xFFC4C6CF),
    outline: const Color(0xFF8D9199),
    outlineVariant: const Color(0xFF43474E),
  );
}

ThemeData getTheme(ColorMode colorMode, Color customColor, Brightness brightness, DynamicColors? dynamicColors) {
  if (colorMode == ColorMode.yaru) {
    return _getYaruTheme(brightness);
  }

  final colorScheme = _determineColorScheme(colorMode, customColor, brightness, dynamicColors);

  final lightInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  final darkInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  // https://github.com/localsend/localsend/issues/52
  final String? fontFamily;
  if (checkPlatform([TargetPlatform.windows])) {
    fontFamily = switch (LocaleSettings.currentLocale) {
      AppLocale.ja => 'Yu Gothic UI',
      AppLocale.ko => 'Malgun Gothic',
      AppLocale.zhCn => 'Microsoft YaHei UI',
      AppLocale.zhHk || AppLocale.zhTw => 'Microsoft JhengHei UI',
      _ => 'Segoe UI Variable Display',
    };
  } else if (checkPlatform([TargetPlatform.linux])) {
    fontFamily = switch (LocaleSettings.currentLocale) {
      AppLocale.ja => 'Noto Sans CJK JP',
      AppLocale.ko => 'Noto Sans CJK KR',
      AppLocale.zhCn => 'Noto Sans CJK SC',
      AppLocale.zhHk || AppLocale.zhTw => 'Noto Sans CJK TC',
      _ => 'Noto Sans',
    };
  } else {
    fontFamily = null;
  }

  return ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
    cardColor: colorScheme.surfaceContainer,
    // Mobile clients draw cards as flat 20dp-radius panels without elevation.
    cardTheme: CardThemeData(
      color: colorScheme.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, space: 1, thickness: 1),
    // same density on all platforms so desktop matches mobile (defaults to compact on desktop)
    visualDensity: VisualDensity.standard,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: colorScheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
      selectedLabelTextStyle: TextStyle(color: colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      focusedBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      enabledBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: colorScheme.brightness == Brightness.dark ? Colors.white : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    fontFamily: fontFamily,
  );
}

Future<void> updateSystemOverlayStyle(BuildContext context) async {
  final brightness = Theme.of(context).brightness;
  await updateSystemOverlayStyleWithBrightness(brightness);
}

Future<void> updateSystemOverlayStyleWithBrightness(Brightness brightness) async {
  if (checkPlatform([TargetPlatform.android])) {
    // See https://github.com/flutter/flutter/issues/90098
    final darkMode = brightness == Brightness.dark;
    final androidSdkInt = RefenaScope.defaultRef.read(deviceInfoProvider).androidSdkInt ?? 0;
    final bool edgeToEdge = androidSdkInt >= 29;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); // ignore: unawaited_futures

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.light ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: edgeToEdge ? Colors.transparent : (darkMode ? Colors.black : Colors.white),
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarIconBrightness: darkMode ? Brightness.light : Brightness.dark,
      ),
    );
  } else {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarBrightness: brightness, // iOS
        statusBarColor: Colors.transparent, // Not relevant to this issue
      ),
    );
  }
}

extension ThemeDataExt on ThemeData {
  /// This is the actual [cardColor] being used.
  Color get cardColorWithElevation {
    return ElevationOverlay.applySurfaceTint(cardColor, colorScheme.surfaceTint, 1);
  }
}

extension ColorSchemeExt on ColorScheme {
  Color get warning {
    return Colors.orange;
  }

  Color? get secondaryContainerIfDark {
    return brightness == Brightness.dark ? secondaryContainer : null;
  }

  Color? get onSecondaryContainerIfDark {
    return brightness == Brightness.dark ? onSecondaryContainer : null;
  }
}

extension InputDecorationThemeExt on InputDecorationThemeData {
  BorderRadius get borderRadius => _borderRadius;
}

ColorScheme _determineColorScheme(ColorMode mode, Color customColor, Brightness brightness, DynamicColors? dynamicColors) {
  final brandColorScheme = _anySendColorScheme(brightness);

  final colorScheme = switch (mode) {
    // The OS accent would break brand parity with the mobile clients, so both
    // the "system" and upstream "localsend" modes stay on the AnySend palette.
    ColorMode.system || ColorMode.localsend => brandColorScheme,
    ColorMode.oled => brandColorScheme.copyWith(
      surface: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: Colors.black,
    ),
    ColorMode.yaru => throw 'Should reach here',
    ColorMode.custom => ColorScheme.fromSeed(
      seedColor: customColor,
      brightness: brightness,
    ),
  };

  return colorScheme;
}

ThemeData _getYaruTheme(Brightness brightness) {
  final baseTheme = brightness == Brightness.light ? yaru.yaruLight : yaru.yaruDark;
  final colorScheme = baseTheme.colorScheme;

  final lightInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  final darkInputBorder = OutlineInputBorder(
    borderSide: BorderSide(color: colorScheme.secondaryContainer),
    borderRadius: _borderRadius,
  );

  InputDecorationThemeData;

  return baseTheme.copyWith(
    // same density on all platforms so desktop matches mobile (defaults to compact on desktop)
    visualDensity: VisualDensity.standard,
    navigationBarTheme: colorScheme.brightness == Brightness.dark
        ? NavigationBarThemeData(
            iconTheme: WidgetStateProperty.all(const IconThemeData(color: Colors.white)),
          )
        : null,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      focusedBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      enabledBorder: colorScheme.brightness == Brightness.light ? lightInputBorder : darkInputBorder,
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: colorScheme.brightness == Brightness.dark ? Colors.white : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
  );
}
