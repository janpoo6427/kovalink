// Review captures of 소유자 등록 on 장치 연결 (not part of `flutter test`).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/owner_pairing_capture_test.dart
//
// The card before registering, the code dialog with a wrong code, the card
// after registering, after another phone registered, and on an older
// kovapilot without owner pairing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/connect/owner_pairing_card.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/owner_pairing.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import '../../test/support/device_profiles.dart';
import 'shot_support.dart';

final _phone = portraitDevices.firstWhere((d) => d.id == 'phone_412x915');

class _ShotLink extends CommaLink {
  _ShotLink({required this.owner, required this.pairing, this.rejected = false})
    : super(
        settings: SettingsController(store: MemorySettingsStore()),
        tokens: MemoryCommaTokenStore(),
      );

  final bool owner;
  final bool? pairing;
  final bool rejected;

  @override
  bool get isOwner => owner;

  @override
  bool get ownerRejected => rejected;

  @override
  set ownerRejected(bool value) {}

  @override
  KovaGatewayHealth? get health => KovaGatewayHealth(
    status: 'ok',
    schemaVersion: 1,
    bindScope: 'wifi',
    authentication: 'localNetwork',
    owner: owner,
    ownerPairing: pairing,
  );

  @override
  set health(KovaGatewayHealth? value) {}

  @override
  Future<OwnerCodeRequest> requestOwnerCode() async =>
      const OwnerCodeShown(120);

  @override
  Future<OwnerCodeResult> confirmOwnerCode(String code) async =>
      const OwnerCodeWrong(4);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _capture(
  WidgetTester tester,
  String name,
  _ShotLink link, {
  Future<void> Function(WidgetTester tester)? act,
}) async {
  _phone.apply(tester);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KovaLinkApp.theme(Brightness.dark),
        home: Scaffold(
          appBar: AppBar(title: const Text('장치 연결')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [OwnerPairingCard(link: link)],
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  await act?.call(tester);
  await _frames(tester);
  await saveBoundary(tester, key, name, pixelRatio: _phone.dpr);
  await tester.pumpWidget(const SizedBox());
  tester.view.reset();
}

void main() {
  testWidgets('owner pairing captures', (tester) async {
    await tester.runAsync(loadReviewFonts);
    await _capture(
      tester,
      'owner_1_not_owner',
      _ShotLink(owner: false, pairing: true),
    );
    await _capture(
      tester,
      'owner_2_code_wrong',
      _ShotLink(owner: false, pairing: true),
      act: (tester) async {
        await tester.tap(find.byKey(const ValueKey('owner-pairing-start')));
        await _frames(tester);
        await tester.enterText(
          find.byKey(const ValueKey('owner-code-field')),
          '482913',
        );
        await tester.tap(find.byKey(const ValueKey('owner-code-submit')));
        await _frames(tester);
      },
    );
    await _capture(
      tester,
      'owner_3_owner',
      _ShotLink(owner: true, pairing: true),
    );
    await _capture(
      tester,
      'owner_4_replaced',
      _ShotLink(owner: false, pairing: true, rejected: true),
    );
    await _capture(
      tester,
      'owner_5_old_kovapilot',
      _ShotLink(owner: false, pairing: null),
    );
  });
}
