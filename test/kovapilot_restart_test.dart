// 콤마 다시 켜기 (POST /v1/device/restart) against the in-memory gateway:
// models, client, controller follow-up until the comma is back, and the
// screen (status card button, staged card button, confirm, progress).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

import 'support/fake_kova_git_gateway.dart';

const _endpoint = 'http://192.168.0.40:8082';
const _shadow = 'feature/longitudinal-shadow';

class _Canned implements KovaParamsTransport {
  _Canned(this.status, this.body);
  final int status;
  final String body;
  final List<String> sent = [];

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async =>
      KovaHttpResponse(status, body);

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async {
    sent.add('${uri.path} $body');
    return KovaHttpResponse(status, this.body);
  }

  @override
  void close() {}
}

Map<String, Object?> _staged(FakeKovaGitGateway g) => {
  'operation': 'switch',
  'branch': _shadow,
  'commit': g.commitOf(_shadow).sha,
  'branchHead': g.commitOf(_shadow).sha,
  'beforeHead': g.head.sha,
  'beforeBranch': g.branch,
  'phase': 'staged',
};

void main() {
  group('models', () {
    test('status carries restartEnabled, absent on older kovapilot', () {
      final on = KovaGitStatus.fromJson({
        'head': 'a' * 40,
        'dirty': false,
        'restartEnabled': true,
      });
      expect(on.restartEnabled, isTrue);
      expect(on.restartSupported, isTrue);
      final off = KovaGitStatus.fromJson({
        'head': 'a' * 40,
        'dirty': false,
        'restartEnabled': false,
      });
      expect(off.restartEnabled, isFalse);
      expect(off.restartSupported, isTrue);
      final old = KovaGitStatus.fromJson({'head': 'a' * 40, 'dirty': false});
      expect(old.restartEnabled, isFalse);
      expect(old.restartSupported, isFalse);
      final odd = KovaGitStatus.fromJson({
        'head': 'a' * 40,
        'dirty': false,
        'restartEnabled': 'yes',
      });
      expect(odd.restartEnabled, isFalse);
      expect(odd.restartSupported, isFalse);
    });
  });

  group('client', () {
    test('restart posts to /v1/device/restart and takes 202', () async {
      final transport = _Canned(202, '{"restarting": true}');
      final client = KovaGitClient(Uri.parse(_endpoint), transport: transport);
      await client.restart();
      expect(transport.sent, ['/v1/device/restart {}']);
    });

    test('a refused restart is one plain line', () async {
      final blocked = KovaGitClient(
        Uri.parse(_endpoint),
        transport: _Canned(
          403,
          '{"error": {"code": "restart_blocked", "message": "restart requires authorized access"}}',
        ),
      );
      await expectLater(
        blocked.restart(),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.restartBlocked)
              .having((e) => e.message, 'message', KovaGitText.restartBlocked),
        ),
      );
      final unavailable = KovaGitClient(
        Uri.parse(_endpoint),
        transport: _Canned(
          503,
          '{"error": {"code": "restart_unavailable", "message": "x"}}',
        ),
      );
      await expectLater(
        unavailable.restart(),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.message,
            'message',
            KovaGitText.restartUnavailable,
          ),
        ),
      );
    });

    test('an older kovapilot without restart is unsupported', () async {
      final gateway = FakeKovaGitGateway.sample();
      final client = KovaGitClient(Uri.parse(_endpoint), transport: gateway);
      await expectLater(
        client.restart(),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.unsupported,
          ),
        ),
      );
      expect((await client.status()).restartSupported, isFalse);
    });
  });

  group('controller', () {
    late FakeKovaGitGateway gateway;
    late KovaGitController controller;

    KovaGitController make({Duration? timeout}) => KovaGitController(
      clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
      followInterval: const Duration(milliseconds: 20),
      restartTimeout: timeout ?? const Duration(seconds: 5),
    );

    setUp(() {
      gateway = FakeKovaGitGateway.sample()
        ..applyEnabled = true
        ..restartEnabled = true;
    });

    tearDown(() => controller.dispose());

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    test(
      'restart, wait while the comma is away, read again once back',
      () async {
        gateway.maintenance = _staged(gateway);
        controller = make();
        await controller.open(_endpoint);
        expect(controller.status!.restartEnabled, isTrue);
        final failure = await controller.restartComma();
        expect(failure, isNull);
        expect(gateway.restartCalls, 1);
        expect(controller.restartState, KovaGitRestart.restarting);
        expect(controller.restartBusy, isTrue);
        expect(
          (await controller.restartComma())!.kind,
          KovaGitFailure.busy,
          reason: 'one restart at a time',
        );
        expect(gateway.restartCalls, 1);
        await until(() => controller.restartState == KovaGitRestart.back);
        expect(
          controller.status!.maintenance!.phase,
          KovaGitMaintenancePhase.installed,
        );
        expect(controller.status!.head, gateway.commitOf(_shadow).sha);
        expect(controller.status!.branch, _shadow);
        final settled = gateway.requests.length;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(gateway.requests.length, settled, reason: 'no more polling');
        await controller.refresh();
        expect(controller.restartState, KovaGitRestart.idle);
      },
    );

    test('a comma that never goes away is not called back', () async {
      gateway.restartDownRequests = 0;
      controller = make(timeout: const Duration(milliseconds: 120));
      await controller.open(_endpoint);
      await controller.restartComma();
      await until(() => controller.restartState == KovaGitRestart.lost);
      final settled = gateway.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(gateway.requests.length, settled, reason: 'stopped waiting');
      await controller.refresh();
      expect(controller.restartState, KovaGitRestart.idle);
      expect(controller.load, KovaGitLoad.ready);
    });

    test('a refused restart is returned and nothing is followed', () async {
      gateway.restartEnabled = false;
      controller = make();
      await controller.open(_endpoint);
      expect(controller.status!.restartEnabled, isFalse);
      final failure = await controller.restartComma();
      expect(failure!.kind, KovaGitFailure.restartBlocked);
      expect(controller.restartState, KovaGitRestart.idle);
      final settled = gateway.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(gateway.requests.length, settled);
    });

    test('no restart while the comma is downloading', () async {
      gateway.maintenance = {..._staged(gateway), 'phase': 'queued'};
      controller = make();
      await controller.open(_endpoint);
      expect(controller.status!.restartEnabled, isFalse);
      expect(
        kovaRestartBlockReason(controller.status!),
        '새 버전을 다 받은 뒤 다시 켤 수 있어요.',
      );
      expect(
        (await controller.restartComma())!.kind,
        KovaGitFailure.restartBlocked,
      );
    });
  });

  group('screen', () {
    Future<(FakeKovaGitGateway, KovaGitController)> open(
      WidgetTester tester, {
      void Function(FakeKovaGitGateway gateway)? setup,
    }) async {
      tester.view.physicalSize = const Size(412, 915) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final gateway = FakeKovaGitGateway.sample()
        ..applyEnabled = true
        ..restartEnabled = true;
      setup?.call(gateway);
      final controller = KovaGitController(
        clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
        followInterval: const Duration(seconds: 3),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: KovaLinkApp.theme(Brightness.dark),
          home: KovaPage(
            title: 'kovapilot 버전',
            backTooltip: KovaRoutes.backToSettings,
            child: KovapilotVersionScreen(
              endpoint: _endpoint,
              controller: controller,
              now: DateTime(2026, 11, 26, 16),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (gateway, controller);
    }

    // Spinners keep pumpAndSettle from settling while the comma restarts.
    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    ButtonStyleButton button(WidgetTester tester, String key) =>
        tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key)));

    Future<void> toTop(WidgetTester tester) async {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await frames(tester);
    }

    testWidgets('a staged update restarts from its card and comes back', (
      tester,
    ) async {
      final (gateway, controller) = await open(
        tester,
        setup: (g) => g.maintenance = _staged(g),
      );
      final short = shortCommit(gateway.commitOf(_shadow).sha);
      expect(find.byKey(const ValueKey('git-maintenance-staged')), findsOne);
      expect(find.text('콤마를 다시 켜면 바뀌어요. 여기서 바로 다시 켤 수 있어요.'), findsOne);
      expect(button(tester, 'git-restart-staged').onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('git-restart-staged')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-restart-dialog')), findsOne);
      expect(find.text('받아 둔 새 버전으로 바뀌어요. 다시 켜는 1~2분 동안 연결이 끊겨요.'), findsOne);
      await tester.tap(find.byKey(const ValueKey('git-restart-confirm')));
      await frames(tester);
      expect(gateway.restartCalls, 1);
      expect(find.byKey(const ValueKey('git-restart-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('git-restart-restarting')), findsOne);
      expect(find.text('콤마를 다시 켜고 있어요.'), findsOne);
      expect(find.byKey(const ValueKey('git-apply-notice')), findsNothing);
      // Both restart buttons are off while it restarts.
      expect(find.byKey(const ValueKey('git-restart-staged')), findsNothing);
      expect(button(tester, 'git-restart').onPressed, isNull);
      expect(find.byKey(const ValueKey('git-refresh')), findsNothing);

      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      await tester.pumpAndSettle();
      expect(controller.restartState, KovaGitRestart.back);
      expect(find.byKey(const ValueKey('git-restart-back')), findsOne);
      expect(find.text('콤마가 다시 켜졌어요.'), findsOne);
      expect(find.byKey(const ValueKey('git-maintenance-installed')), findsOne);
      expect(find.text('‘$_shadow’ 브랜치의 $short 커밋으로 바뀌었어요.'), findsOne);
      expect(gateway.restartCalls, 1);
    });

    testWidgets('the status card restarts after asking, and cancel does not', (
      tester,
    ) async {
      final (gateway, _) = await open(tester);
      expect(find.byKey(const ValueKey('git-restart-reason')), findsNothing);
      final restart = find.byKey(const ValueKey('git-restart'));
      await tester.ensureVisible(restart);
      await tester.pumpAndSettle();
      await tester.tap(restart);
      await tester.pumpAndSettle();
      expect(find.text('다시 켜는 1~2분 동안 연결이 끊겨요.'), findsOne);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(gateway.restartCalls, 0);
      expect(
        find.byKey(const ValueKey('git-restart-restarting')),
        findsNothing,
      );

      await tester.tap(restart);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('git-restart-confirm')));
      await frames(tester);
      expect(gateway.restartCalls, 1);
      // The button says it right where it was pressed.
      expect(find.text('콤마를 다시 켜고 있어요'), findsOne);
      await toTop(tester);
      expect(find.byKey(const ValueKey('git-restart-restarting')), findsOne);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-restart-back')), findsOne);
      expect(find.text('콤마 다시 켜기'), findsOne);
    });

    testWidgets('a comma that does not come back says so', (tester) async {
      final (gateway, controller) = await open(
        tester,
        setup: (g) => g.restartDownRequests = 1000,
      );
      final restart = find.byKey(const ValueKey('git-restart'));
      await tester.ensureVisible(restart);
      await tester.pumpAndSettle();
      await tester.tap(restart);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('git-restart-confirm')));
      await frames(tester);
      for (var i = 0; i < 81; i++) {
        await tester.pump(const Duration(seconds: 3));
      }
      await tester.pumpAndSettle();
      await toTop(tester);
      expect(controller.restartState, KovaGitRestart.lost);
      expect(find.text('콤마가 아직 다시 연결되지 않았어요.'), findsOne);
      expect(find.byKey(const ValueKey('git-restart-refresh')), findsOne);
      expect(gateway.restartCalls, 1);
    });

    testWidgets('car on: the button is off with the reason', (tester) async {
      await open(tester, setup: (g) => g.restartEnabled = false);
      expect(button(tester, 'git-restart').onPressed, isNull);
      expect(find.text('시동을 끄면 다시 켤 수 있어요.'), findsOne);
    });

    testWidgets('a staged update with the car on keeps the old words', (
      tester,
    ) async {
      final (gateway, _) = await open(
        tester,
        setup: (g) => g
          ..restartEnabled = false
          ..maintenance = _staged(g),
      );
      expect(find.byKey(const ValueKey('git-restart-staged')), findsNothing);
      expect(find.textContaining('콤마 화면의 업데이트 알림에서'), findsOne);
      expect(gateway.restartCalls, 0);
    });

    testWidgets('an older kovapilot shows no restart button', (tester) async {
      await open(tester, setup: (g) => g.restartEnabled = null);
      expect(find.byKey(const ValueKey('git-restart')), findsNothing);
      expect(find.byKey(const ValueKey('git-restart-reason')), findsNothing);
    });

    testWidgets('a refused restart says why and stays ready', (tester) async {
      final (gateway, controller) = await open(tester);
      final restart = find.byKey(const ValueKey('git-restart'));
      await tester.ensureVisible(restart);
      await tester.pumpAndSettle();
      await tester.tap(restart);
      await tester.pumpAndSettle();
      // The car was started while the dialog was open.
      gateway.restartEnabled = false;
      await tester.tap(find.byKey(const ValueKey('git-restart-confirm')));
      await tester.pumpAndSettle();
      expect(find.text(KovaGitText.restartBlocked), findsOne);
      expect(controller.restartState, KovaGitRestart.idle);
    });
  });

  test('words', () {
    KovaGitStatus status({
      String? block,
      String? updater = 'idle',
      bool enabled = false,
    }) => KovaGitStatus(
      head: 'a' * 40,
      mutationBlock: block,
      updaterState: updater,
      restartEnabled: enabled,
      restartSupported: true,
    );
    expect(kovaRestartBlockReason(status(enabled: true)), isNull);
    expect(
      kovaRestartBlockReason(status(block: 'authorization')),
      '등록한 휴대폰으로 연결해야 다시 켤 수 있어요.',
    );
    expect(
      kovaRestartBlockReason(status(updater: 'finalizing update...')),
      '콤마가 새 버전을 준비하는 동안은 다시 켤 수 없어요.',
    );
    expect(kovaRestartBlockReason(status()), '시동을 끄면 다시 켤 수 있어요.');
  });
}
