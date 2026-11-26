// 적용 (POST /v1/git/apply) end to end against the in-memory gateway:
// models, client body and answers, controller follow-up, and the screen.
import 'dart:convert';

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

KovaGitClient _client(FakeKovaGitGateway gateway) =>
    KovaGitClient(Uri.parse(_endpoint), transport: gateway);

class _Canned implements KovaParamsTransport {
  _Canned(this.status, this.body);
  final int status;
  final String body;
  String? sent;

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async =>
      KovaHttpResponse(status, body);

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async {
    sent = body;
    return KovaHttpResponse(status, this.body);
  }

  @override
  void close() {}
}

void main() {
  group('models', () {
    test('status carries the block and the last request', () {
      final status = KovaGitStatus.fromJson({
        'branch': 'master',
        'head': 'a' * 40,
        'dirty': true,
        'dirtyKnown': false,
        'mutationEnabled': false,
        'mutationBlock': 'offroadOrUpdaterBusy',
        'maintenance': {
          'phase': 'queued',
          'branch': 'feature/x',
          'commit': 'b' * 40,
        },
      });
      expect(status.mutationBlock, 'offroadOrUpdaterBusy');
      expect(status.maintenance!.phase, KovaGitMaintenancePhase.queued);
      expect(status.maintenance!.branch, 'feature/x');
      expect(status.maintenance!.commit, 'b' * 40);
      expect(status.applying, isTrue);
    });

    test('an unreadable maintenance entry is none, not a failure', () {
      for (final bad in [
        {'phase': 'later', 'branch': 'x'},
        {'phase': 'queued'},
        'queued',
      ]) {
        final status = KovaGitStatus.fromJson({
          'branch': 'master',
          'head': 'a' * 40,
          'dirty': false,
          'maintenance': bad,
        });
        expect(status.maintenance, isNull, reason: '$bad');
        expect(status.applying, isFalse);
      }
    });

    test('installed and failed are not active', () {
      for (final (phase, active) in [
        ('queued', true),
        ('staged', true),
        ('installed', false),
        ('failed', false),
      ]) {
        final m = KovaGitMaintenance.fromJson({
          'phase': phase,
          'branch': 'master',
          'reason': phase == 'failed' ? 'stagingFailed' : null,
        });
        expect(m.active, active, reason: phase);
      }
    });
  });

  group('client', () {
    test('apply sends the previewed request with its digest', () async {
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      final client = _client(gateway);
      final request = const KovaGitPlanRequest.switchTo(_shadow);
      final plan = await client.plan(request);
      expect(plan.mutationEnabled, isTrue);
      final queued = await client.apply(plan.planDigest, request: request);
      expect(queued.phase, KovaGitMaintenancePhase.queued);
      expect(queued.branch, _shadow);
      expect(queued.commit, gateway.commitOf(_shadow).sha);
      expect(gateway.applies.single, {
        'operation': 'switch',
        'branch': _shadow,
        'planDigest': plan.planDigest,
      });
      final status = await client.status();
      expect(status.applying, isTrue);
      expect(status.mutationEnabled, isFalse);
    });

    test('a reset carries its full commit', () async {
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      final client = _client(gateway);
      final older = gateway.headHistory()[4].sha;
      final request = KovaGitPlanRequest.resetTo(
        branch: 'master',
        commit: older,
      );
      final plan = await client.plan(request);
      await client.apply(plan.planDigest, request: request);
      expect(gateway.applies.single['commit'], older);
      expect(gateway.maintenance!['commit'], older);
    });

    test('a moved preview is 409 and nothing is queued', () async {
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      final client = _client(gateway);
      final request = const KovaGitPlanRequest.switchTo(_shadow);
      final plan = await client.plan(request);
      gateway.commitOnComma('fix: made on the comma');
      await expectLater(
        client.apply(plan.planDigest, request: request),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.planChanged)
              .having((e) => e.message, 'message', KovaGitText.planChanged),
        ),
      );
      expect(gateway.maintenance, isNull);
    });

    test('a dirty comma is refused with git_apply_blocked', () async {
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      final client = _client(gateway);
      final request = const KovaGitPlanRequest.switchTo(_shadow);
      final plan = await client.plan(request);
      gateway.dirty = true;
      await expectLater(
        client.apply(plan.planDigest, request: request),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.applyBlocked)
              .having((e) => e.message, 'message', KovaGitText.applyBlocked),
        ),
      );
      expect(gateway.maintenance, isNull);
    });

    test('a second apply while one is with the updater is refused', () async {
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      final client = _client(gateway);
      final request = const KovaGitPlanRequest.switchTo(_shadow);
      final plan = await client.plan(request);
      await client.apply(plan.planDigest, request: request);
      await expectLater(
        client.apply(plan.planDigest, request: request),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.mutationDisabled,
          ),
        ),
      );
      expect(gateway.applyCalls, 2);
      expect(gateway.applies, hasLength(1));
    });

    test('202 without a maintenance entry is a format failure', () async {
      final canned = _Canned(202, '{"ok": true}');
      final client = KovaGitClient(Uri.parse(_endpoint), transport: canned);
      await expectLater(
        client.apply(
          '0' * 64,
          request: const KovaGitPlanRequest.switchTo('master'),
        ),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.format,
          ),
        ),
      );
      expect(jsonDecode(canned.sent!), {
        'operation': 'switch',
        'branch': 'master',
        'planDigest': '0' * 64,
      });
    });

    test('the comma words stay out of the error', () async {
      for (final (status, code, kind) in [
        (409, 'git_plan_changed', KovaGitFailure.planChanged),
        (403, 'git_apply_blocked', KovaGitFailure.applyBlocked),
        (403, 'git_mutation_disabled', KovaGitFailure.mutationDisabled),
      ]) {
        final client = KovaGitClient(
          Uri.parse(_endpoint),
          transport: _Canned(
            status,
            jsonEncode({
              'error': {'code': code, 'message': 'Traceback secret'},
            }),
          ),
        );
        await expectLater(
          client.apply('0' * 64),
          throwsA(
            isA<KovaGitException>()
                .having((e) => e.kind, 'kind', kind)
                .having(
                  (e) => e.message.contains('Traceback'),
                  'leaks',
                  isFalse,
                ),
          ),
        );
      }
    });
  });

  group('controller', () {
    late FakeKovaGitGateway gateway;
    late KovaGitController controller;

    setUp(() {
      gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
      controller = KovaGitController(
        clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
        followInterval: const Duration(milliseconds: 20),
      );
    });

    tearDown(() => controller.dispose());

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue);
    }

    test('apply, follow the download, stop once staged', () async {
      await controller.open(_endpoint);
      const request = KovaGitPlanRequest.switchTo(_shadow);
      final plan = (await controller.preview(request)).plan!;
      final failure = await controller.apply(request, plan);
      expect(failure, isNull);
      expect(controller.sending, isFalse);
      expect(controller.downloading, isTrue);
      expect(controller.status!.maintenance!.branch, _shadow);
      final reads = gateway.requests.where((r) => r == '/v1/git/status');
      final before = reads.length;
      await until(
        () =>
            gateway.requests.where((r) => r == '/v1/git/status').length >
            before + 1,
      );
      gateway.stage();
      await until(
        () =>
            controller.status!.maintenance!.phase ==
                KovaGitMaintenancePhase.staged &&
            controller.load == KovaGitLoad.ready,
      );
      expect(controller.downloading, isFalse);
      final settled = gateway.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(gateway.requests.length, settled, reason: 'no more polling');
    });

    test('a failed download shows the failure and stops', () async {
      await controller.open(_endpoint);
      const request = KovaGitPlanRequest.switchTo(_shadow);
      final plan = (await controller.preview(request)).plan!;
      await controller.apply(request, plan);
      gateway.failApply('stagingFailed');
      await until(
        () =>
            controller.status!.maintenance!.phase ==
            KovaGitMaintenancePhase.failed,
      );
      expect(controller.status!.maintenance!.reason, 'stagingFailed');
      expect(controller.status!.applying, isFalse);
    });

    test('a refused apply is returned and nothing is followed', () async {
      gateway.applyEnabled = false;
      await controller.open(_endpoint);
      const request = KovaGitPlanRequest.switchTo(_shadow);
      final plan = (await controller.preview(request)).plan!;
      final failure = await controller.apply(request, plan);
      expect(failure!.kind, KovaGitFailure.mutationDisabled);
      expect(controller.downloading, isFalse);
    });

    test('opening while the comma downloads follows it', () async {
      const request = KovaGitPlanRequest.switchTo(_shadow);
      final client = KovaGitClient.tryCreate(_endpoint, transport: gateway)!;
      final plan = await client.plan(request);
      await client.apply(plan.planDigest, request: request);
      await controller.open(_endpoint);
      expect(controller.downloading, isTrue);
      gateway.stage();
      await until(() => !controller.downloading);
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
      final gateway = FakeKovaGitGateway.sample()..applyEnabled = true;
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

    FilledButton applyButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('git-apply')));

    // The download card spins, so pumpAndSettle never settles while queued.
    Future<void> frames(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('적용 switches through the updater and says to restart', (
      tester,
    ) async {
      final (gateway, controller) = await open(tester);
      expect(find.textContaining('미리 본 뒤 적용할 수 있어요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('git-branch-$_shadow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-apply-ready')), findsOneWidget);
      expect(find.byKey(const ValueKey('git-apply-locked')), findsNothing);
      expect(applyButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('git-apply')));
      await frames(tester);
      expect(find.byKey(const ValueKey('git-preview-dialog')), findsNothing);
      expect(find.text('콤마가 새 버전을 받기 시작했어요.'), findsOneWidget);
      expect(gateway.applies.single['branch'], _shadow);
      final short = shortCommit(gateway.commitOf(_shadow).sha);
      expect(find.text('‘$_shadow’ 브랜치의 $short 커밋을 받고 있어요.'), findsOneWidget);
      expect(find.byKey(const ValueKey('git-maintenance-queued')), findsOne);
      expect(find.byKey(const ValueKey('git-apply-notice')), findsNothing);
      expect(find.text('바꾸는 동안은 확인하지 않아요'), findsOneWidget);

      gateway.stage();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-maintenance-staged')), findsOne);
      expect(find.text('‘$_shadow’ 브랜치의 $short 커밋을 받아 뒀어요.'), findsOneWidget);
      expect(find.textContaining('콤마를 다시 켜면 바뀌어요.'), findsOneWidget);

      gateway.install();
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-maintenance-installed')), findsOne);
      expect(find.text('‘$_shadow’ 브랜치의 $short 커밋으로 바뀌었어요.'), findsOneWidget);
      expect(find.textContaining('미리 본 뒤 적용할 수 있어요'), findsOneWidget);
    });

    testWidgets('적용 stays off with the comma reason', (tester) async {
      await open(
        tester,
        setup: (g) => g
          ..applyEnabled = false
          ..mutationBlock = 'offroadOrUpdaterBusy',
      );
      const reason = '시동을 끄고, 콤마가 다른 업데이트를 하지 않을 때 바꿀 수 있어요.';
      expect(find.text('지금은 미리보기만 할 수 있어요. $reason'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('git-branch-$_shadow')));
      await tester.pumpAndSettle();
      expect(applyButton(tester).onPressed, isNull);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('git-apply-locked')),
          matching: find.text(reason),
        ),
        findsOneWidget,
      );
    });

    testWidgets('nothing to change, or modified files, keeps 적용 off', (
      tester,
    ) async {
      final (gateway, _) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('git-branch-master')));
      await tester.pumpAndSettle();
      expect(applyButton(tester).onPressed, isNull);
      expect(find.text('이미 이 커밋이라 바꿀 게 없어요.'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();

      gateway.dirty = true;
      await tester.tap(find.byKey(const ValueKey('git-branch-$_shadow')));
      await tester.pumpAndSettle();
      expect(applyButton(tester).onPressed, isNull);
      expect(find.text('콤마에 수정된 파일이 있어서 바꿀 수 없어요.'), findsOneWidget);
      expect(gateway.applyCalls, 0);
    });

    testWidgets('a moved preview says so and can be asked again', (
      tester,
    ) async {
      final (gateway, _) = await open(tester);
      await tester.tap(find.byKey(const ValueKey('git-branch-$_shadow')));
      await tester.pumpAndSettle();
      gateway.origin[_shadow] = gateway.commitOnComma('moved');
      gateway.head = gateway.commitOf('master');
      await tester.tap(find.byKey(const ValueKey('git-apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-preview-dialog')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('git-apply-failure')),
          matching: find.text(KovaGitText.planChanged),
        ),
        findsOneWidget,
      );
      expect(gateway.maintenance, isNull);
      await tester.tap(find.text('다시 물어보기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-apply-failure')), findsNothing);
      expect(applyButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('git-apply')));
      await frames(tester);
      expect(gateway.maintenance!['phase'], 'queued');
      // Let the follow-up stop before the test ends.
      gateway.stage();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('git-maintenance-staged')), findsOne);
    });

    testWidgets('a failed download says why', (tester) async {
      await open(
        tester,
        setup: (g) => g.maintenance = {
          'operation': 'switch',
          'branch': _shadow,
          'commit': g.commitOf(_shadow).sha,
          'phase': 'failed',
          'reason': 'stagingFailed',
        },
      );
      expect(find.byKey(const ValueKey('git-maintenance-failed')), findsOne);
      expect(find.text(kovaApplyFailureText('stagingFailed')), findsOneWidget);
    });
  });

  test('words', () {
    expect(kovaMutationBlockText(null), KovaGitText.mutationDisabled);
    expect(kovaMutationBlockText('authorization'), '등록한 휴대폰으로 연결해야 바꿀 수 있어요.');
    expect(kovaApplyFailureText('nope'), '콤마에서 바꾸기가 멈췄어요. 다시 해 주세요.');
    expect(
      kovaApplyTargetText(
        const KovaGitMaintenance(
          phase: KovaGitMaintenancePhase.queued,
          branch: 'master',
        ),
      ),
      '‘master’ 브랜치의 새 버전',
    );
  });
}
