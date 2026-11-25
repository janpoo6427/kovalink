// Every screen that replaces the whole screen is a route on the app's one
// Navigator, so the system back (Android back button and Android 13+
// predictive back gesture, iOS edge swipe) walks back through what the user
// opened. Only the drive screen at the bottom of the stack leaves the app.
//
//   /                          drive screen (always at the bottom)
//   /connect                   장치 연결                      pushed
//   /connect/register          콤마 등록 (from 장치 연결)     pushed
//   /settings/app              설정, 앱 탭                    pushed
//   /settings/session          설정, 연결 상태 탭             replaces the tab shown
//   /settings/kovapilot        설정, kovapilot 탭             replaces the tab shown
//   /settings/app/diagnostics  진단 (from the 앱 tab)         pushed
//   /settings/kovapilot/version  kovapilot 버전 (from the kovapilot tab)  pushed
//
// Settings tabs replace each other, so back from any tab goes straight to
// the drive screen. Dialogs and bottom sheets stay what they are (their own
// popup routes, closed by back first).
import 'package:flutter/material.dart';
import 'package:kovalink/src/widgets/glass_nav_button.dart';

abstract final class KovaRoutes {
  static const drive = Navigator.defaultRouteName;
  static const connect = '/connect';
  static const settingsApp = '/settings/app';
  static const settingsSession = '/settings/session';
  static const settingsKovapilot = '/settings/kovapilot';
  static const diagnostics = '/settings/app/diagnostics';
  static const kovapilotVersion = '/settings/kovapilot/version';

  /// Back button tooltip on pages opened from the drive screen.
  static const backToDrive = '주행 화면으로 돌아가기';

  /// Back button tooltip on pages opened from settings.
  static const backToSettings = '설정으로 돌아가기';

  /// Pushes [route] unless the screen asking is no longer on top (a
  /// second tap while the first page is already sliding in).
  static Future<T?>? open<T>(BuildContext context, Route<T> route) {
    if (ModalRoute.of(context)?.isCurrent == false) return null;
    return Navigator.of(context).push(route);
  }

  /// Replaces the current page with [route] (settings tabs), with the same
  /// guard as [open].
  static Future<T?>? replace<T>(BuildContext context, Route<T> route) {
    if (ModalRoute.of(context)?.isCurrent == false) return null;
    return Navigator.of(context).pushReplacement(route);
  }
}

/// Platform page route (predictive back on Android, edge swipe on iOS)
/// carrying its [KovaRoutes] name.
class KovaPageRoute<T> extends MaterialPageRoute<T> {
  KovaPageRoute({
    required String name,
    required super.builder,
    this.instant = false,
  }) : super(settings: RouteSettings(name: name));

  /// Shows up at once instead of sliding in: one settings tab replacing
  /// another. Going back still animates, and the back gestures still work.
  final bool instant;

  @override
  Duration get transitionDuration =>
      instant ? Duration.zero : super.transitionDuration;
}

/// A full-screen page above the drive screen: [child] (usually a
/// ReadableListView, which leaves room on top) under the floating back
/// button in the top left corner.
class KovaPage extends StatelessWidget {
  const KovaPage({
    required this.child,
    this.backTooltip = KovaRoutes.backToDrive,
    super.key,
  });

  final Widget child;
  final String backTooltip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned(
              left: 16,
              top: 14,
              child: GlassNavButton(
                tooltip: backTooltip,
                icon: Icons.arrow_back_rounded,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
