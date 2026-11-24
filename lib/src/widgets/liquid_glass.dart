import 'dart:ui';

import 'package:flutter/material.dart';

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(12),
    this.radius = 22,
    this.tint = const Color(0x38FFFFFF),
    this.blur = 20,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color tint;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint.withValues(alpha: tint.a * 1.35),
                tint.withValues(alpha: tint.a * 0.45),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
              BoxShadow(
                color: Color(0x33FFFFFF),
                blurRadius: 1,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
