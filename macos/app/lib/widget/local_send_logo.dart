import 'package:flutter/material.dart';
import 'package:localsend_app/gen/assets.gen.dart';

class LocalSendLogo extends StatelessWidget {
  final bool withText;

  const LocalSendLogo({required this.withText});

  @override
  Widget build(BuildContext context) {
    final logo = ColorFiltered(
      colorFilter: ColorFilter.mode(
        Theme.of(context).colorScheme.primary,
        BlendMode.srcATop,
      ),
      child: Assets.img.logo512.image(
        width: 200,
        height: 200,
      ),
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const SizedBox(height: 4),
          Text(
            'AnySend',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}
