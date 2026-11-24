import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';

void main() {
  testWidgets('shows the KovaLink road view', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(const KovaLinkApp());
    await tester.pump();
    expect(find.text('제한속도'), findsOneWidget);
    expect(find.text('좌회전'), findsOneWidget);
    expect(find.byTooltip('장치 연결'), findsOneWidget);
    expect(find.byTooltip('설정'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });
}
