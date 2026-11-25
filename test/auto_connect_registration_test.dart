// The Finder with registration: only the registered comma (same pin, any
// address) is connected on its own; other commas are listed to register;
// a new IP of the registered comma is found again; another certificate at
// the same address is not taken for it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/network/comma_advert_source.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';

import 'support/fake_auto_connect.dart';
import 'support/fake_wifi_gateway.dart';

final _wifi = LocalNetwork.named('wlan0', '192.168.43.5');

KovaDevice _comma(String host, String pin) => KovaDevice(
  host: host,
  port: 8082,
  secure: true,
  pin: fixturePin(pin),
  bindScope: 'wifi',
);

class _Adverts implements CommaAdvertSource {
  _Adverts(this.addresses);
  final List<({String host, int port})> addresses;
  int lookups = 0;

  @override
  Future<List<({String host, int port})>> lookup(Duration timeout) async {
    lookups++;
    return addresses;
  }

  @override
  void close() {}
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  late FakeProbe probe;
  late FakeTarget target;
  String? registeredPin;
  bool canAttach(KovaDevice d) =>
      !d.secure ||
      (registeredPin != null && d.pin == fixturePin(registeredPin!));

  AutoConnectController controller({
    String? last,
    CommaAdvertSource? adverts,
    Duration heartbeat = const Duration(seconds: 10),
  }) => AutoConnectController(
    target: target,
    probe: probe,
    listNetworks: () async => [_wifi],
    lastEndpoint: () => last,
    canAttach: canAttach,
    adverts: adverts,
    advertWait: Duration.zero,
    heartbeatInterval: heartbeat,
    networkWatchInterval: const Duration(minutes: 5),
  );

  setUp(() {
    probe = FakeProbe();
    target = FakeTarget();
    registeredPin = null;
  });

  testWidgets('the registered comma at a new IP is connected on its own', (
    tester,
  ) async {
    registeredPin = pinDeviceA;
    probe.answers['192.168.43.77:8082'] = ProbeResult.kova(
      _comma('192.168.43.77', pinDeviceA),
    );
    final auto = controller(last: 'https://192.168.43.20:8082');
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.connected);
    expect(target.attached.single.host, '192.168.43.77');
    expect(probe.calls.first, '192.168.43.20:8082', reason: 'last IP first');
    auto.dispose();
  });

  testWidgets('an unregistered comma is listed, never connected', (
    tester,
  ) async {
    probe.answers['192.168.43.77:8082'] = ProbeResult.kova(
      _comma('192.168.43.77', pinDeviceB),
    );
    final auto = controller();
    final registerTaps = <KovaDevice>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutoConnectPanel(
              controller: auto,
              onRegister: registerTaps.add,
              onConnectByIp: () {},
            ),
          ),
        ),
      ),
    );
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.choosing);
    expect(auto.problem, KovaLinkProblem.needsRegistration);
    expect(target.attached, isEmpty);
    await auto.choose(auto.found.single);
    expect(target.attached, isEmpty, reason: 'choose needs registration');
    expect(find.text('콤마 · 192.168.43.77'), findsOneWidget);
    expect(find.text('등록하면 연결할 수 있어요'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('auto-connect-choose-192.168.43.77:8082')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('auto-connect-register-192.168.43.77:8082')),
    );
    expect(registerTaps.single.pin!.hex, pinDeviceB);
    expect(
      find.text(KovaLinkText.message(KovaLinkProblem.needsRegistration)),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    auto.dispose();
  });

  testWidgets('registered and unregistered both there: the registered one', (
    tester,
  ) async {
    registeredPin = pinDeviceA;
    probe.answers['192.168.43.30:8082'] = ProbeResult.kova(
      _comma('192.168.43.30', pinDeviceB),
    );
    probe.answers['192.168.43.31:8082'] = ProbeResult.kova(
      _comma('192.168.43.31', pinDeviceA),
    );
    final auto = controller();
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.connected);
    expect(target.attached.single.host, '192.168.43.31');
    auto.dispose();
  });

  testWidgets('a different certificate at the same IP is not the comma', (
    tester,
  ) async {
    registeredPin = pinDeviceA;
    probe.answers['192.168.43.20:8082'] = ProbeResult.kova(
      _comma('192.168.43.20', pinDeviceA),
    );
    final auto = controller(
      last: 'https://192.168.43.20:8082',
      heartbeat: const Duration(milliseconds: 100),
    );
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.connected);
    // Something else takes the address.
    probe.answers['192.168.43.20:8082'] = ProbeResult.kova(
      _comma('192.168.43.20', pinDeviceB),
    );
    await tester.pump(const Duration(milliseconds: 150));
    await _settle(tester);
    expect(auto.device, isNull);
    expect(target.detached.single.pin!.hex, pinDeviceA);
    expect(
      auto.log.map((e) => e.message),
      contains(
        contains(KovaLinkText.message(KovaLinkProblem.identityMismatch)),
      ),
    );
    auto.dispose();
  });

  testWidgets('hold: the comma answered but the token was refused', (
    tester,
  ) async {
    registeredPin = pinDeviceA;
    final device = _comma('192.168.43.20', pinDeviceA);
    probe.answers['192.168.43.20:8082'] = ProbeResult.kova(device);
    final auto = controller();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutoConnectPanel(
              controller: auto,
              onRegister: (_) {},
              onConnectByIp: () {},
            ),
          ),
        ),
      ),
    );
    auto.setEnabled(true);
    await _settle(tester);
    auto.hold(device, KovaLinkProblem.tokenRejected);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.needsAttention);
    expect(auto.statusLabel, '콤마 확인 필요');
    expect(
      find.text(KovaLinkText.message(KovaLinkProblem.tokenRejected)),
      findsOneWidget,
    );
    expect(
      find.text(KovaLinkText.detail(KovaLinkProblem.tokenRejected)),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('link-problem-more')));
    await tester.pump();
    expect(
      find.text(KovaLinkText.detail(KovaLinkProblem.tokenRejected)),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('auto-connect-register-192.168.43.20:8082')),
      findsOneWidget,
      reason: 'register again with the new token',
    );
    final calls = probe.calls.length;
    await tester.pump(const Duration(seconds: 30));
    expect(probe.calls.length, calls, reason: 'no retry loop with a bad token');
    await tester.pumpWidget(const SizedBox());
    auto.dispose();
  });

  testWidgets('only a refusing comma: same network / phone not allowed', (
    tester,
  ) async {
    probe.answers['192.168.43.20:8082'] = ProbeResult.refused(
      _comma('192.168.43.20', pinDeviceA),
    );
    final auto = controller();
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.waiting);
    expect(auto.problem, KovaLinkProblem.notAllowed);
    expect(auto.refused.single.host, '192.168.43.20');
    auto.dispose();
  });

  testWidgets('nothing found: the big IP로 연결', (tester) async {
    final auto = controller();
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutoConnectPanel(
              controller: auto,
              onConnectByIp: () => opened++,
            ),
          ),
        ),
      ),
    );
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.waiting);
    expect(auto.problem, KovaLinkProblem.notFound);
    final button = find.byKey(const ValueKey('connect-by-ip'));
    expect(button, findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('IP로 연결'),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(
      find.text(KovaLinkText.message(KovaLinkProblem.notFound)),
      findsOneWidget,
    );
    await tester.tap(button);
    expect(opened, 1);
    await tester.pumpWidget(const SizedBox());
    auto.dispose();
  });

  testWidgets('an announced address is checked like any other', (tester) async {
    registeredPin = pinDeviceA;
    probe.answers['192.168.43.99:8082'] = ProbeResult.kova(
      _comma('192.168.43.99', pinDeviceA),
    );
    final adverts = _Adverts([
      (host: '192.168.43.99', port: 8082),
      (host: '8.8.8.8', port: 8082),
    ]);
    final auto = controller(adverts: adverts);
    auto.setEnabled(true);
    await _settle(tester);
    expect(adverts.lookups, 1);
    expect(auto.phase, AutoConnectPhase.connected);
    expect(target.attached.single.host, '192.168.43.99');
    expect(probe.calls, isNot(contains('8.8.8.8:8082')));
    expect(probe.violations, isEmpty);
    // Announced address was tried before the subnet scan reached .99.
    final index = probe.calls.indexOf('192.168.43.99:8082');
    expect(
      probe.calls.sublist(0, index).where((c) => c.startsWith('192.168.43.2')),
      isEmpty,
    );
    expect(kovaLinkServiceType, '_kovalink._tcp');
    auto.dispose();
  });

  testWidgets('IP entry: check then connect, also with 자동 연결 off', (
    tester,
  ) async {
    registeredPin = pinDeviceA;
    probe.answers['192.168.43.20:8082'] = ProbeResult.kova(
      _comma('192.168.43.20', pinDeviceA),
    );
    final auto = controller();
    final result = await auto.check('192.168.43.20', 8082);
    expect(result.outcome, ProbeOutcome.kova);
    expect(auto.phase, AutoConnectPhase.off);
    await auto.connectTo(result.device!);
    expect(target.attached.single.host, '192.168.43.20');
    expect(auto.phase, AutoConnectPhase.connected);
    expect((await auto.check('8.8.8.8', 8082)).outcome, ProbeOutcome.noAnswer);
    expect(probe.calls, isNot(contains('8.8.8.8:8082')));
    auto.dispose();
  });
}
