import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Widest the connect/settings pages grow. On tablets and in landscape the
/// cards keep a readable width and center instead of stretching.
const double readablePageWidth = 720;

/// Full-screen page list under the floating back button: 64 on top for the
/// button, 20 at the sides (more on wide screens, to center
/// [readablePageWidth]) and the bottom inset plus 32 below.
class ReadableListView extends StatelessWidget {
  const ReadableListView({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final side = math.max(20.0, (box.maxWidth - readablePageWidth) / 2);
      return ListView(
        padding: EdgeInsets.fromLTRB(
          side,
          8,
          side,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: children,
      );
    },
  );
}
