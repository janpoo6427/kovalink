import 'package:flutter/material.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

/// Round glass button floating over the road view and the pages (drive
/// screen buttons, page back button).
class GlassNavButton extends StatelessWidget {
  const GlassNavButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: LiquidGlass(
        radius: 24,
        blur: 18,
        tint: const Color(0x8CFFFFFF),
        padding: EdgeInsets.zero,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, color: const Color(0xFF15191E)),
          iconSize: 21,
        ),
      ),
    );
  }
}
