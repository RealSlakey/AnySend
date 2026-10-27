import 'package:flutter/material.dart';

class CustomListTile extends StatelessWidget {
  final Widget? icon;
  final Widget title;
  final Widget subTitle;
  final Widget? trailing;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  const CustomListTile({
    this.icon,
    required this.title,
    required this.subTitle,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      // Matches the Android `CardPanel`: flat, 20dp corners, no outline.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      color: theme.colorScheme.surfaceContainerLowest,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              if (icon != null) ...[
                icon!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      child: title,
                    ),
                    const SizedBox(height: 2),
                    subTitle,
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
