// A kovapilot gateway that refuses phones for now (403
// local_client_required, its loopback-only development bind) is "found, not
// allowed yet" everywhere: discovery, 자동 연결, the settings client.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';

import 'support/fake_auto_connect.dart';

// Body of a real kovapilot gateway (master-jh@7cc3b3280) answering
// GET /v1/health with a LAN Host header.
const _refusal =
    '{"error": {"code": "local_client_required", '
    '"message": "only loopback host names are supported"}}';

class _Canned implements KovaParamsTransport {
  _Canned(this.status, this.body);
  final int status;
  final String body;

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async =>
      KovaHttpResponse(status, body);

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async => KovaHttpResponse(status, this.body);

  @override
  void close() {}
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

void main() {
  group('health answer', () {
    test('403 local_client_required is a comma that refuses phones', () {
      final r = judgeHealthResponse('192.168.0.40', 8082, 403, _refusal);
      expect(r.outcome, ProbeOutcome.localOnly);
      expect(r.device, isNull);
      expect(isKovaLocalOnlyRefusal(403, _refusal), isTrue);
    });

    test('other 403s are still not a comma', () {
      for (final body in [
        '{"error": {"code": "update_forbidden", "message": "x"}}',
        '<html>forbidden</html>',
        '{"error": "local_client_required"}',
      ]) {
        expect(
          judgeHealthResponse('192.168.0.40', 8082, 403, body).outcome,
          ProbeOutcome.notKova,
          reason: body,
        );
      }
      expect(
        judgeHealthResponse('192.168.0.40', 8082, 401, _refusal).outcome,
        ProbeOutcome.notKova,
      );
    });
  });

  testWidgets('자동 연결: found, not allowed yet; never "not a comma"', (
    tester,
  ) async {
    final probe = FakeProbe();
    probe.answers['192.168.0.40:8082'] = const ProbeResult.localOnly();
    final auto = AutoConnectController(
      target: FakeTarget(),
      probe: probe,
      listNetworks: () async => [LocalNetwork.named('wlan0', '192.168.0.23')],
      lastEndpoint: () => 'http://192.168.0.40:8082',
    );
    auto.setEnabled(true);
    await _settle(tester);
    expect(auto.phase, AutoConnectPhase.waiting);
    expect(auto.device, isNull);
    expect(auto.localOnly, ['192.168.0.40']);
    final log = auto.log.map((e) => e.message).toList();
    expect(log, contains('192.168.0.40 · $kovaLocalOnlyMessage'));
    expect(log, contains('$kovaLocalOnlyMessage.'));
    expect(log, isNot(contains('콤마를 찾지 못했어요.')));
    expect(log.where((l) => l.contains('콤마가 아니에요')), isEmpty);
    expect(auto.statusLabel, '콤마 찾음 · 휴대폰 연결 아직 허용 안 됨');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutoConnectPanel(controller: auto),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('192.168.0.40: $kovaLocalOnlyMessage.'),
      findsOneWidget,
    );
    expect(find.textContaining('콤마가 아니에요'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auto.dispose();
    expect(probe.violations, isEmpty);
  });

  test('settings client says the same', () async {
    final client = KovaParamsClient(
      Uri.parse('http://192.168.0.40:8082'),
      transport: _Canned(403, _refusal),
    );
    await expectLater(
      client.fetch(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.message,
          'message',
          '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.',
        ),
      ),
    );
    final update =
        await client.update('steering.always_on', true, 0)
            as KovaUpdateRejected;
    expect(update.reason, '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.');
    expect(jsonDecode(_refusal)['error']['code'], 'local_client_required');
  });
}
