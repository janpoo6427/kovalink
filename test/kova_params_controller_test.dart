import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';

import 'support/fake_kova_gateway.dart';

KovaParamsController _controller(
  FakeKovaGateway gateway, {
  DateTime Function()? clock,
  bool Function()? isAuthenticated,
}) => KovaParamsController(
  clientFactory: (endpoint, onError) => KovaParamsClient.tryCreate(
    endpoint,
    transport: gateway,
    onError: onError,
  ),
  pollInterval: null,
  clock: clock,
  isAuthenticated: isAuthenticated,
);

void main() {
  late FakeKovaGateway gateway;
  late KovaParamsController kova;

  setUp(() {
    gateway = FakeKovaGateway();
    kova = _controller(gateway);
  });

  tearDown(() => kova.dispose());

  test('starts disconnected and locked; no request is made', () async {
    expect(kova.status, KovaLinkStatus.disconnected);
    expect(kova.writeLock, KovaWriteLock.notConnected);
    expect(await kova.setValue('e2e.level', 4), isNull);
    expect(gateway.gets, 0);
    expect(gateway.posts, isEmpty);
  });

  test('a public address is refused without network', () async {
    final error = await kova.connect('http://example.com:8082');
    expect(error, contains('같은 네트워크'));
    expect(kova.status, KovaLinkStatus.disconnected);
    expect(gateway.gets, 0);
  });

  group('write lock', () {
    test('LAN addresses stay read-only until pairing', () async {
      for (final address in [
        'http://192.168.0.10:8082',
        'http://comma.local:8082',
        'http://10.0.0.5:8082',
        'http://[fd00::5]:8082',
      ]) {
        expect(await kova.connect(address), isNull, reason: address);
        expect(kova.status, KovaLinkStatus.connected);
        expect(kova.writeLock, KovaWriteLock.needsPairing, reason: address);
        expect(
          kova.lockReasonFor(kova.document!.setting('e2e.level')!),
          contains('보기만'),
        );
        expect(await kova.setValue('e2e.level', 4), isNull);
      }
      expect(gateway.posts, isEmpty);
    });

    test('loopback addresses can write', () async {
      for (final address in [
        'http://127.0.0.1:18082',
        'http://localhost:18082',
        'http://[::1]:18082',
      ]) {
        await kova.connect(address);
        expect(kova.writeLock, KovaWriteLock.none, reason: address);
        expect(kova.isLoopback, isTrue);
      }
    });

    test('a paired session would unlock LAN writes', () async {
      final paired = _controller(gateway, isAuthenticated: () => true);
      addTearDown(paired.dispose);
      await paired.connect('http://192.168.0.10:8082');
      expect(paired.writeLock, KovaWriteLock.none);
    });

    test(
      'onroad locks offroad and restart settings but not immediate ones',
      () async {
        gateway.offroad = false;
        await kova.connect('http://127.0.0.1:18082');
        final doc = kova.document!;
        expect(doc.deviceOffroad, isFalse);
        expect(
          kova.lockReasonFor(doc.setting('steering.always_on')!),
          contains('시동을 끈 뒤'),
        );
        expect(
          kova.lockReasonFor(doc.setting('e2e.gain')!),
          contains('시동을 끈 뒤'),
        );
        expect(kova.lockReasonFor(doc.setting('e2e.level')!), isNull);
        expect(
          kova.lockReasonFor(doc.setting('e2e.build_label')!),
          contains('읽기 전용'),
        );
        expect(await kova.setValue('steering.always_on', true), isNull);
        expect(gateway.posts, isEmpty);
      },
    );

    test(
      'without a device state the gateway decides, and its refusal is shown',
      () async {
        gateway
          ..offroad = false
          ..reportOffroad = false;
        await kova.connect('http://127.0.0.1:18082');
        expect(
          kova.lockReasonFor(kova.document!.setting('steering.always_on')!),
          isNull,
        );
        final outcome = await kova.setValue('steering.always_on', true);
        expect(outcome, isA<KovaUpdateRejected>());
        expect(
          kova.notices['steering.always_on']!.kind,
          KovaNoticeKind.rejected,
        );
        expect(
          kova.notices['steering.always_on']!.message,
          contains('시동을 끈 뒤'),
        );
        expect(kova.document!.setting('steering.always_on')!.value, isFalse);
      },
    );
  });

  group('sending', () {
    setUp(() => kova.connect('http://127.0.0.1:18082'));

    test('shows pending, then only the gateway-confirmed value', () async {
      final future = kova.setValue('e2e.level', 7);
      expect(kova.pending, {'e2e.level': 7});
      expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.sending);
      expect(kova.document!.setting('e2e.level')!.value, 3);
      expect(
        kova.lockReasonFor(kova.document!.setting('e2e.level')!),
        contains('보내는 중'),
      );
      expect(await future, isA<KovaUpdateApplied>());
      expect(kova.pending, isEmpty);
      expect(kova.document!.revision, 1);
      expect(kova.document!.setting('e2e.level')!.value, 7);
      expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.applied);
      expect(gateway.posts.single, {
        'key': 'e2e.level',
        'value': 7,
        'expectedRevision': 0,
      });
    });

    test('a local range error is shown and nothing is sent', () async {
      expect(await kova.setValue('e2e.level', 42), isNull);
      expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.rejected);
      expect(gateway.posts, isEmpty);
    });

    test(
      'a gateway rejection keeps the old value and shows the reason',
      () async {
        // Bypass the local check by changing the catalog bound after reading.
        final setting = (gateway.catalog['settings'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((s) => s['key'] == 'e2e.level');
        setting['maximum'] = 5;
        final outcome = await kova.setValue('e2e.level', 8);
        expect(outcome, isA<KovaUpdateRejected>());
        expect(kova.notices['e2e.level']!.message, contains('범위'));
        expect(kova.document!.setting('e2e.level')!.value, 3);
        expect(kova.pending, isEmpty);
      },
    );

    test(
      'a revision conflict re-reads and asks the user to choose again',
      () async {
        gateway.externalWrite('e2e.level', 9);
        final outcome = await kova.setValue('e2e.level', 4);
        expect(outcome, isA<KovaUpdateConflict>());
        expect(kova.document!.revision, 1);
        expect(kova.document!.setting('e2e.level')!.value, 9);
        final notice = kova.notices['e2e.level']!;
        expect(notice.kind, KovaNoticeKind.conflict);
        expect(notice.message, contains('지금 값: 9 단계'));
        expect(notice.message, contains('이전: 3 단계'));
        expect(gateway.values['e2e.level'], 9);
      },
    );

    test('a timeout is not a success: the device value is re-read', () async {
      gateway.nextPost = FakePostMode.timeout;
      expect(await kova.setValue('e2e.level', 6), isA<KovaUpdateTimedOut>());
      expect(kova.document!.setting('e2e.level')!.value, 3);
      expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.timedOut);

      gateway.nextPost = FakePostMode.timeoutButApplied;
      expect(await kova.setValue('e2e.level', 6), isA<KovaUpdateTimedOut>());
      // The value appears only because the re-read showed it.
      expect(kova.document!.setting('e2e.level')!.value, 6);
      expect(kova.document!.revision, 1);
      expect(kova.pending, isEmpty);
    });

    test(
      'a dropped connection marks the data stale and locks writes',
      () async {
        gateway.nextPost = FakePostMode.fail;
        gateway.down = false;
        final outcome = kova.setValue('e2e.level', 6);
        gateway.down = true;
        expect(await outcome, isA<KovaUpdateFailed>());
        expect(kova.status, KovaLinkStatus.stale);
        expect(kova.writeLock, KovaWriteLock.stale);
        expect(kova.notices['e2e.level']!.kind, KovaNoticeKind.failed);
        expect(await kova.setValue('e2e.level', 5), isNull);

        gateway.down = false;
        expect(await kova.refresh(), isTrue);
        expect(kova.status, KovaLinkStatus.connected);
        expect(kova.writeLock, KovaWriteLock.none);
      },
    );

    test('an unknown major schema on refresh closes the document', () async {
      gateway.extra = {'schemaVersion': 2};
      expect(await kova.refresh(), isFalse);
      expect(kova.document, isNull);
      expect(kova.status, KovaLinkStatus.disconnected);
      expect(kova.error, contains('앱을 업데이트'));
    });

    test('disconnect clears session state', () async {
      kova.disconnect();
      expect(kova.document, isNull);
      expect(kova.status, KovaLinkStatus.disconnected);
      expect(kova.writeLock, KovaWriteLock.notConnected);
    });
  });

  test('old data is shown as stale', () async {
    var now = DateTime(2026, 11, 25, 9);
    final timed = _controller(gateway, clock: () => now);
    addTearDown(timed.dispose);
    await timed.connect('http://127.0.0.1:18082');
    expect(timed.status, KovaLinkStatus.connected);
    now = now.add(const Duration(minutes: 2));
    expect(timed.status, KovaLinkStatus.stale);
    expect(timed.writeLock, KovaWriteLock.stale);
    await timed.refresh();
    expect(timed.status, KovaLinkStatus.connected);
  });
}
