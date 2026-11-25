// End-to-end transport test against a real kovapilot gateway process.
//
// Skipped unless KOVA_E2E_GATEWAY_HOOK points at a hook script that can
// start/stop the gateway (tool/e2e/kovapilot_gateway_hook.sh). Run:
//
//   KOVAPILOT_DIR=~/kova/wt/senior-gateway \
//   KOVA_E2E_GATEWAY_HOOK=tool/e2e/kovapilot_gateway_hook.sh \
//   flutter test test/kovapilot_gateway_e2e_test.dart
//
// The gateway binds 127.0.0.1 only; the hook runs it in the kovapilot
// container with `--network host` so this test reaches it on loopback.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';

final String? _hook = Platform.environment['KOVA_E2E_GATEWAY_HOOK'];
final int _port =
    int.tryParse(Platform.environment['KOVA_E2E_PORT'] ?? '') ?? 18082;
final String _origin = 'http://127.0.0.1:$_port';

Future<void> hook(List<String> args) async {
  final result = await Process.run('bash', [_hook!, ...args]);
  if (result.exitCode != 0) {
    fail(
      'hook ${args.join(' ')} failed (${result.exitCode}): ${result.stdout}\n${result.stderr}',
    );
  }
}

KovaParamsClient _client({Duration timeout = const Duration(seconds: 3)}) =>
    KovaParamsClient.tryCreate(_origin, timeout: timeout)!;

KovaParamsController _controller({
  Duration timeout = const Duration(seconds: 3),
}) => KovaParamsController(
  clientFactory: (endpoint, onError) =>
      KovaParamsClient.tryCreate(endpoint, timeout: timeout, onError: onError),
  pollInterval: null,
);

/// Raw POST for requests the typed client never builds.
Future<(int, Map<String, dynamic>)> _rawPost(Object body) async {
  final http = HttpClient();
  try {
    final request = await http.postUrl(
      Uri.parse('$_origin/v1/kova-params/update'),
    );
    request.headers.contentType = ContentType.json;
    request.write(body is String ? body : jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
  } finally {
    http.close(force: true);
  }
}

void main() {
  final skip = _hook == null
      ? 'KOVA_E2E_GATEWAY_HOOK not set (real gateway e2e)'
      : null;

  group('bundled catalog via python -m openpilot.kovapilot.gateway', () {
    setUpAll(() async {
      await hook(['reset']);
      await hook(['start', 'bundled']);
    });
    tearDownAll(() async => hook(['stop']));

    test('health', () async {
      final client = _client();
      addTearDown(client.close);
      final health = await client.health();
      expect(health.status, 'ok');
      expect(health.schemaVersion, 1);
      expect(health.bindScope, 'loopback');
      expect(health.authentication, 'localProcessOnly');
    });

    test('catalog read', () async {
      final client = _client();
      addTearDown(client.close);
      final doc = await client.fetch();
      expect(doc.revision, 0);
      expect(doc.deviceOffroad, isTrue);
      final s = doc.setting('steering.always_on')!;
      expect(s.title.resolve(), '항시 조향');
      expect(s.title.resolve(preferred: const ['en']), 'Always-on steering');
      expect(s.control, KovaParamControl.toggle);
      expect(s.status, KovaAvailability.pendingConsumer);
      expect(s.value, isFalse);
      expect(doc.groups.single.id, 'steering');
    });

    test('update, revision +1, re-read matches', () async {
      final kova = _controller();
      addTearDown(kova.dispose);
      expect(await kova.connect(_origin), isNull);
      expect(kova.writeLock, KovaWriteLock.none);
      final outcome = await kova.setValue('steering.always_on', true);
      expect(outcome, isA<KovaUpdateApplied>());
      expect(kova.document!.revision, 1);
      final client = _client();
      addTearDown(client.close);
      final reread = await client.fetch();
      expect(reread.revision, 1);
      expect(reread.setting('steering.always_on')!.value, isTrue);
    });

    test('value survives a gateway restart', () async {
      await hook(['stop']);
      await hook(['start', 'bundled']);
      final client = _client();
      addTearDown(client.close);
      final doc = await client.fetch();
      expect(doc.revision, 1);
      expect(doc.setting('steering.always_on')!.value, isTrue);
    });

    test('stale revision is a conflict and the controller re-reads', () async {
      final client = _client();
      addTearDown(client.close);
      expect(
        await client.update('steering.always_on', false, 0),
        isA<KovaUpdateConflict>(),
      );

      final kova = _controller();
      addTearDown(kova.dispose);
      await kova.connect(_origin);
      // Another writer moves the revision after KovaLink read it.
      expect(
        await client.update('steering.always_on', false, 1),
        isA<KovaUpdateApplied>(),
      );
      final outcome = await kova.setValue('steering.always_on', true);
      expect(outcome, isA<KovaUpdateConflict>());
      expect(kova.notices['steering.always_on']!.kind, KovaNoticeKind.conflict);
      expect(kova.document!.revision, 2);
      expect(kova.document!.setting('steering.always_on')!.value, isFalse);
    });

    test(
      'wrong type, unknown key and malformed requests are refused',
      () async {
        final client = _client();
        addTearDown(client.close);
        final type =
            await client.update('steering.always_on', 1, 2)
                as KovaUpdateRejected;
        expect((type.statusCode, type.code), (400, 'invalid_value'));
        final unknown =
            await client.update('steering.nope', true, 2) as KovaUpdateRejected;
        expect((unknown.statusCode, unknown.code), (400, 'invalid_value'));
        expect(unknown.reason, contains('모르는 항목'));
        final extra = await _rawPost({
          'key': 'steering.always_on',
          'value': true,
          'expectedRevision': 2,
          'isOffroad': true,
        });
        expect(extra.$1, 400);
        expect(extra.$2['error']['code'], 'invalid_request');
        final bad = await _rawPost('{not-json');
        expect(bad.$2['error']['code'], 'invalid_json');
        expect((await client.fetch()).revision, 2);
      },
    );

    test('onroad (IsOffroad=false) refuses the offroad setting', () async {
      await hook(['offroad', 'false']);
      addTearDown(() => hook(['offroad', 'true']));
      final kova = _controller();
      addTearDown(kova.dispose);
      await kova.connect(_origin);
      final doc = kova.document!;
      expect(doc.deviceOffroad, isFalse);
      expect(
        kova.lockReasonFor(doc.setting('steering.always_on')!),
        contains('주행 중'),
      );
      final client = _client();
      addTearDown(client.close);
      final refused =
          await client.update('steering.always_on', true, doc.revision)
              as KovaUpdateRejected;
      expect((refused.statusCode, refused.code), (403, 'update_forbidden'));
      expect(refused.reason, contains('주행 중'));
      expect((await client.fetch()).revision, doc.revision);
    });

    test('the loopback-only bind does not answer on a LAN address', () async {
      final lan = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .toList();
      if (lan.isEmpty) {
        markTestSkipped('no LAN IPv4 address on this host');
        return;
      }
      final client = KovaParamsClient(
        Uri.parse('http://${lan.first}:$_port'),
        timeout: const Duration(seconds: 2),
      );
      addTearDown(client.close);
      await expectLater(
        client.health(),
        throwsA(
          isA<KovaParamsException>().having(
            (e) => e.kind,
            'kind',
            KovaFailureKind.transport,
          ),
        ),
      );
    });
  }, skip: skip);

  group('fixture catalog via tools/kovapilot/kovalink_gateway_dev.py', () {
    setUpAll(() async {
      await hook(['reset']);
      await hook(['start', 'fixture']);
    });
    tearDownAll(() async {
      await hook(['resume']);
      await hook(['stop']);
    });

    test(
      'hidden, read-only, range and enum metadata survive the wire',
      () async {
        final client = _client();
        addTearDown(client.close);
        final doc = await client.fetch();
        expect(doc.groups.map((g) => g.id), ['steering', 'e2e']);
        expect(
          doc.groups.expand((g) => g.settings).map((s) => s.key),
          isNot(contains('e2e.hidden_flag')),
        );
        expect(doc.setting('e2e.level')!.control, KovaParamControl.slider);
        expect(doc.setting('e2e.level')!.unit!.resolve(), '단계');
        expect(doc.setting('e2e.gain')!.applyPolicy, KovaApplyPolicy.restart);
        expect(doc.setting('e2e.mode')!.options.map((o) => o.label()), [
          '차분하게',
          '보통',
          '활발하게',
        ]);
        expect(
          doc.setting('e2e.build_label')!.control,
          KovaParamControl.readOnly,
        );
      },
    );

    test('range: inside accepted, outside refused by the gateway', () async {
      final client = _client();
      addTearDown(client.close);
      for (final (key, value) in [
        ('e2e.level', 11),
        ('e2e.level', -1),
        ('e2e.gain', 2.5),
        ('e2e.gain', 0.4),
      ]) {
        final refused =
            await client.update(key, value, 0) as KovaUpdateRejected;
        expect(
          (refused.statusCode, refused.code),
          (400, 'invalid_value'),
          reason: '$key=$value',
        );
        expect(refused.reason, contains('범위'));
      }
      final readOnly =
          await client.update('e2e.build_label', 'x', 0) as KovaUpdateRejected;
      expect(readOnly.statusCode, 403);
      final kova = _controller();
      addTearDown(kova.dispose);
      await kova.connect(_origin);
      expect(await kova.setValue('e2e.level', 10), isA<KovaUpdateApplied>());
      expect(await kova.setValue('e2e.gain', 1.5), isA<KovaUpdateApplied>());
      expect(await kova.setValue('e2e.mode', 'calm'), isA<KovaUpdateApplied>());
      final doc = await client.fetch();
      expect(doc.revision, 3);
      expect(doc.setting('e2e.level')!.value, 10);
      expect(doc.setting('e2e.gain')!.value, 1.5);
      expect(doc.setting('e2e.mode')!.value, 'calm');
    });

    test(
      'onroad: immediate allowed, offroad refused, restart left to the client lock',
      () async {
        await hook(['offroad', 'false']);
        addTearDown(() => hook(['offroad', 'true']));
        final kova = _controller();
        addTearDown(kova.dispose);
        await kova.connect(_origin);
        final doc = kova.document!;
        expect(await kova.setValue('e2e.level', 2), isA<KovaUpdateApplied>());
        expect(kova.lockReasonFor(doc.setting('e2e.gain')!), contains('주행 중'));
        final client = _client();
        addTearDown(client.close);
        final revision = (await client.fetch()).revision;
        final refused =
            await client.update('steering.always_on', true, revision)
                as KovaUpdateRejected;
        expect(refused.code, 'update_forbidden');
        // The gateway itself only enforces `offroad`; `restart` is accepted.
        expect(
          await client.update('e2e.gain', 1.2, revision),
          isA<KovaUpdateApplied>(),
        );
      },
    );

    test(
      'timeout is never success: the controller re-reads the device value',
      () async {
        final kova = _controller(timeout: const Duration(milliseconds: 1500));
        addTearDown(kova.dispose);
        await kova.connect(_origin);
        final before = kova.document!;
        await hook(['pause']);
        final outcome = await kova.setValue('e2e.level', 7);
        expect(outcome, isA<KovaUpdateTimedOut>());
        expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.timedOut);
        // Not assumed: still the last confirmed document.
        expect(kova.document!.revision, before.revision);
        expect(
          kova.document!.setting('e2e.level')!.value,
          before.setting('e2e.level')!.value,
        );
        expect(kova.status, KovaLinkStatus.stale);
        expect(kova.writeLock, KovaWriteLock.stale);

        await hook(['resume']);
        expect(await kova.refresh(), isTrue);
        final client = _client();
        addTearDown(client.close);
        final device = await client.fetch();
        // Whatever the device decided, the app now shows exactly that.
        expect(kova.document!.revision, device.revision);
        expect(
          kova.document!.setting('e2e.level')!.value,
          device.setting('e2e.level')!.value,
        );
        // ignore: avoid_print
        print(
          'timeout case: device level=${device.setting('e2e.level')!.value} revision=${device.revision} (before ${before.revision})',
        );
      },
    );

    test(
      'gateway stopped: stale, writes locked, reconnect after restart',
      () async {
        final kova = _controller();
        addTearDown(kova.dispose);
        await kova.connect(_origin);
        await hook(['stop']);
        expect(await kova.refresh(), isFalse);
        expect(kova.status, KovaLinkStatus.stale);
        expect(kova.writeLock, KovaWriteLock.stale);
        expect(await kova.setValue('e2e.level', 1), isNull);
        final fresh = _controller();
        addTearDown(fresh.dispose);
        expect(await fresh.connect(_origin), isNotNull);
        expect(fresh.status, KovaLinkStatus.disconnected);

        await hook(['start', 'fixture']);
        expect(await kova.refresh(), isTrue);
        expect(kova.status, KovaLinkStatus.connected);
        expect(kova.writeLock, KovaWriteLock.none);
      },
    );
  }, skip: skip);
}
