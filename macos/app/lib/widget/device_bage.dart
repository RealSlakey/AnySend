import 'package:flutter/material.dart';

class DeviceBadge extends StatelessWidget {
  final Color backgroundColor;
  final Color foregroundColor;
  final String label;

  const DeviceBadge({
    required this.backgroundColor,
    required this.foregroundColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      // Mobile clients render metadata as 12sp muted pills.
      child: Text(label, style: TextStyle(color: foregroundColor, fontSize: 12)),
    );
  }
}
