import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';

import 'support/fake_auto_connect.dart';

final wifi = LocalNetwork.named('wlan0', '192.168.0.23');
final cellular = LocalNetwork.named('rmnet_data0', '10.20.30.40');

class Rig {
  Rig({List<LocalNetwork>? nets, this.last, int concurrency = 24}) {
    networks = nets ?? [wifi, cellular];
    auto = AutoConnectController(
      target: target,
      probe: probe,
      listNetworks: () async => networks,
      lastEndpoint: () => last,
      concurrency: concurrency,
    );
  }

  final probe = FakeProbe();
  final target = FakeTarget();
  late List<LocalNetwork> networks;
  String? last;
  late final AutoConnectController auto;

  List<String> get log => auto.log.map((e) => e.message).toList();

  /// Disposes and checks that no probe ever left the endpoint policy.
  void finish() {
    auto.dispose();
    expect(probe.violations, isEmpty);
    expect(probe.closed, isTrue);
  }
}

Future<void> settle(WidgetTester tester, [Duration? by]) async {
  await tester.pump(by);
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('last successful address is tried first and used directly', (
    tester,
  ) async {
    final rig = Rig(last: 'http://192.168.0.40:8082');
    rig.probe.device('192.168.0.40');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.probe.calls, ['192.168.0.40:8082']);
    expect(rig.target.attached.single.label, '192.168.0.40:8082');
    rig.finish();
  });

  testWidgets('order: last → router .1 → subnet scan; one device connects', (
    tester,
  ) async {
    final rig = Rig(last: 'http://192.168.0.40:8082');
    rig.probe.device('192.168.0.77');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.probe.calls.take(2), ['192.168.0.40:8082', '192.168.0.1:8082']);
    expect(rig.probe.calls.skip(2).first, '192.168.0.2:8082');
    // The whole /24 (minus own, last and router) was probed once each.
    expect(rig.probe.calls, hasLength(253));
    expect(rig.probe.calls.toSet(), hasLength(253));
    expect(rig.probe.calls.where((c) => c.startsWith('10.20.30.')), isEmpty);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.auto.device!.host, '192.168.0.77');
    expect(rig.target.attached, hasLength(1));
    expect(rig.log, contains('마지막 주소 192.168.0.40 · 답이 없어요'));
    rig.finish();
  });

  testWidgets('a known router address connects without the full scan', (
    tester,
  ) async {
    final rig = Rig();
    rig.probe.device('192.168.0.1');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.probe.calls, ['192.168.0.1:8082']);
    expect(rig.auto.device!.host, '192.168.0.1');
    rig.finish();
  });

  testWidgets('backoff 1 → 2 → 5 → 10 → 15 s, capped', (tester) async {
    final rig = Rig();
    rig.auto.setEnabled(true);
    await settle(tester);
    final delays = <int>[];
    final passStarts = <int>[];
    for (var i = 0; i < 7; i++) {
      expect(rig.auto.phase, AutoConnectPhase.waiting);
      final wait = rig.auto.nextRetry!;
      delays.add(wait.inSeconds);
      final before = rig.probe.calls.length;
      // Nothing happens before the delay is over.
      await settle(tester, wait - const Duration(milliseconds: 200));
      expect(rig.probe.calls.length, before);
      await settle(tester, const Duration(milliseconds: 200));
      passStarts.add(rig.probe.calls.length - before);
      expect(rig.auto.attempt, i + 2);
    }
    expect(delays, [1, 2, 5, 10, 15, 15, 15]);
    expect(passStarts.every((n) => n == 253), isTrue);
    rig.finish();
  });

  testWidgets('only mobile data: nothing is probed, retries stay cheap', (
    tester,
  ) async {
    final rig = Rig(
      nets: [cellular, LocalNetwork.named('wlan0', '203.0.113.5')],
      last: 'http://192.168.0.40:8082',
    );
    rig.auto.setEnabled(true);
    await settle(tester);
    await settle(tester, const Duration(seconds: 40));
    expect(rig.probe.calls, isEmpty);
    expect(rig.auto.phase, AutoConnectPhase.waiting);
    expect(rig.log, contains('연결된 와이파이·핫스팟이 없어요. 모바일 데이터로는 찾지 않아요.'));
    rig.finish();
  });

  testWidgets('an open port that is not kovapilot is not connected', (
    tester,
  ) async {
    final rig = Rig();
    rig.probe.other('192.168.0.30');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.waiting);
    expect(rig.target.attached, isEmpty);
    expect(rig.log.where((l) => l == '192.168.0.30 · 콤마가 아니에요'), hasLength(1));
    rig.finish();
  });

  testWidgets('several devices are listed; the chosen one connects', (
    tester,
  ) async {
    final rig = Rig();
    rig.probe.device('192.168.0.40');
    rig.probe.device('192.168.0.41');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.choosing);
    expect(rig.auto.found.map((d) => d.host), ['192.168.0.40', '192.168.0.41']);
    expect(rig.target.attached, isEmpty);
    // Waiting for the choice does not start new passes.
    final calls = rig.probe.calls.length;
    await settle(tester, const Duration(seconds: 30));
    expect(rig.probe.calls.length, calls);
    await rig.auto.choose(rig.auto.found[1]);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.target.attached.single.host, '192.168.0.41');
    rig.finish();
  });

  testWidgets('heartbeat: two misses → search again → reconnect', (
    tester,
  ) async {
    final rig = Rig(last: 'http://192.168.0.40:8082');
    rig.probe.device('192.168.0.40');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    await settle(tester, const Duration(seconds: 10));
    expect(rig.target.kept, hasLength(1));

    rig.probe.gone('192.168.0.40');
    await settle(tester, const Duration(seconds: 10));
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.log.last, '콤마가 답이 없어요 (1/2).');
    await settle(tester, const Duration(seconds: 10));
    expect(rig.target.detached, hasLength(1));
    expect(rig.auto.phase, AutoConnectPhase.waiting);
    expect(rig.auto.attempt, 1);

    rig.probe.device('192.168.0.40');
    await settle(tester, const Duration(seconds: 1));
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.target.attached, hasLength(2));
    rig.finish();
  });

  testWidgets('telemetry drop with a silent device searches right away', (
    tester,
  ) async {
    final rig = Rig(last: 'http://192.168.0.40:8082');
    rig.probe.device('192.168.0.40');
    rig.auto.setEnabled(true);
    await settle(tester);
    rig.probe.gone('192.168.0.40');
    rig.auto.connectionLost();
    await settle(tester);
    expect(rig.target.detached, hasLength(1));
    expect(rig.auto.phase, AutoConnectPhase.waiting);
    rig.finish();
  });

  testWidgets('turning 자동 연결 off stops every probe', (tester) async {
    final rig = Rig();
    rig.auto.setEnabled(true);
    await settle(tester);
    rig.auto.setEnabled(false);
    final calls = rig.probe.calls.length;
    await settle(tester, const Duration(minutes: 2));
    expect(rig.probe.calls.length, calls);
    expect(rig.auto.phase, AutoConnectPhase.off);
    expect(rig.auto.statusLabel, '자동 연결 꺼짐');
    rig.probe.device('192.168.0.9');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    rig.finish();
  });

  testWidgets('never starts while disabled (default before settings load)', (
    tester,
  ) async {
    final rig = Rig();
    await settle(tester, const Duration(minutes: 1));
    expect(rig.probe.calls, isEmpty);
    expect(rig.auto.phase, AutoConnectPhase.off);
    rig.finish();
  });

  testWidgets('background / screen off pauses; resume searches at once', (
    tester,
  ) async {
    final rig = Rig();
    rig.auto.setEnabled(true);
    await settle(tester);
    rig.auto.setForeground(false);
    final calls = rig.probe.calls.length;
    await settle(tester, const Duration(minutes: 5));
    expect(rig.probe.calls.length, calls);
    expect(rig.auto.phase, AutoConnectPhase.paused);
    rig.probe.device('192.168.0.50');
    rig.auto.setForeground(true);
    await settle(tester);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    rig.finish();
  });

  testWidgets('a network change restarts the search without waiting', (
    tester,
  ) async {
    final rig = Rig(nets: [cellular]);
    rig.auto.setEnabled(true);
    await settle(tester);
    // Walk the backoff up to 15 s.
    for (final s in [1, 2, 5, 10]) {
      await settle(tester, Duration(seconds: s));
    }
    expect(rig.auto.nextRetry, const Duration(seconds: 15));
    // Hotspot comes up; the comma joins it.
    rig.networks = [cellular, LocalNetwork.named('swlan0', '10.155.70.1')];
    rig.probe.device('10.155.70.23');
    await settle(tester, const Duration(seconds: 4));
    expect(rig.log, contains('네트워크가 바뀌었어요.'));
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.auto.device!.host, '10.155.70.23');
    rig.finish();
  });

  testWidgets('parallel scan respects the connection limit', (tester) async {
    final rig = Rig(concurrency: 8);
    rig.probe.delay = const Duration(milliseconds: 300);
    rig.probe.device('192.168.0.200');
    rig.auto.setEnabled(true);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await settle(tester);
    expect(rig.probe.maxInFlight, 8);
    expect(rig.auto.phase, AutoConnectPhase.connected);
    rig.finish();
  });

  testWidgets('데모 보기 keeps the comma but does not reopen telemetry', (
    tester,
  ) async {
    final rig = Rig(last: 'http://192.168.0.40:8082');
    rig.probe.device('192.168.0.40');
    rig.auto.setEnabled(true);
    await settle(tester);
    expect(rig.target.attachedTelemetry, [true]);
    // The user taps 데모 보기 while the car is live.
    rig.auto.telemetryLeftByUser();
    await settle(tester, const Duration(seconds: 10));
    await settle(tester, const Duration(seconds: 10));
    expect(rig.auto.phase, AutoConnectPhase.connected);
    expect(rig.target.keptTelemetry, isNotEmpty);
    expect(rig.target.keptTelemetry.every((open) => !open), isTrue);
    expect(rig.target.detached, isEmpty);
    // 지금 찾기 lifts the hold.
    rig.auto.retryNow();
    await settle(tester);
    expect(rig.target.attachedTelemetry, [true, true]);
    rig.finish();
  });
}
