import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

import 'support/fake_kova_git_gateway.dart';

void main() {
  late FakeKovaGitGateway gateway;
  late KovaGitController controller;

  setUp(() {
    gateway = FakeKovaGitGateway.sample();
    controller = KovaGitController(
      clientFactory: (endpoint) =>
          KovaGitClient.tryCreate(endpoint, transport: gateway),
    );
  });

  tearDown(() => controller.dispose());

  test('opens with status, branches and the first page', () async {
    final states = <KovaGitLoad>[];
    controller.addListener(() => states.add(controller.load));
    await controller.open('http://127.0.0.1:8082');
    expect(states, [KovaGitLoad.loading, KovaGitLoad.ready]);
    expect(controller.status!.branch, 'master');
    expect(controller.branches, hasLength(4));
    expect(controller.log, hasLength(20));
    expect(controller.hasMoreLog, isTrue);
    // One inspection at a time: status, branches, then log.
    expect(gateway.requests, [
      '/v1/git/status',
      '/v1/git/branches',
      '/v1/git/log?limit=20&cursor=0',
    ]);
  });

  test('more history until the end, without duplicates', () async {
    await controller.open('http://127.0.0.1:8082');
    await controller.loadMore();
    expect(controller.log, hasLength(30));
    expect(controller.hasMoreLog, isFalse);
    expect(controller.log.map((e) => e.commit).toSet(), hasLength(30));
    await controller.loadMore();
    expect(
      gateway.requests.where((r) => r.startsWith('/v1/git/log')),
      hasLength(2),
    );
  });

  test('a failed page keeps what was loaded and can be retried', () async {
    await controller.open('http://127.0.0.1:8082');
    gateway.mode = FakeGitMode.busy;
    await controller.loadMore();
    expect(controller.log, hasLength(20));
    expect(controller.logFailure!.kind, KovaGitFailure.busy);
    expect(controller.loadingMore, isFalse);
    gateway.mode = FakeGitMode.normal;
    await controller.loadMore();
    expect(controller.log, hasLength(30));
    expect(controller.logFailure, isNull);
  });

  test('branch search, tracked branch first', () async {
    await controller.open('http://127.0.0.1:8082');
    expect(controller.visibleBranches.first.name, 'master');
    expect(controller.visibleBranches.skip(1).map((b) => b.name), [
      'feature/ccnc-display-sync',
      'feature/longitudinal-shadow',
      'release/stable',
    ]);
    controller.setQuery('  SHADOW ');
    expect(controller.visibleBranches.map((b) => b.name), [
      'feature/longitudinal-shadow',
    ]);
    controller.setQuery('nothing-like-this');
    expect(controller.visibleBranches, isEmpty);
    controller.setQuery('');
    expect(controller.isCurrent(controller.visibleBranches.first), isTrue);
    expect(controller.isCurrent(controller.visibleBranches.last), isFalse);
  });

  test('reset is checked against the tracked branch by default', () async {
    await controller.open('http://127.0.0.1:8082');
    expect(controller.defaultResetBranch, 'master');
    gateway
      ..branch = 'release/stable'
      ..upstream = null;
    await controller.refresh();
    expect(controller.defaultResetBranch, 'release/stable');
    gateway.branch = null;
    await controller.refresh();
    expect(controller.defaultResetBranch, isNull);
  });

  test('previews never apply', () async {
    await controller.open('http://127.0.0.1:8082');
    final preview = await controller.preview(
      const KovaGitPlanRequest.switchTo('release/stable'),
    );
    expect(preview.plan!.branch, 'release/stable');
    expect(preview.plan!.mutationEnabled, isFalse);
    final older = controller.log[3].commit;
    final reset = await controller.preview(
      KovaGitPlanRequest.resetTo(branch: 'master', commit: older),
    );
    expect(reset.plan!.commit, older);
    final refused = await controller.preview(
      KovaGitPlanRequest.resetTo(
        branch: 'release/stable',
        commit: gateway.commitOf('master').sha,
      ),
    );
    expect(refused.plan, isNull);
    expect(refused.failure!.kind, KovaGitFailure.invalidRequest);
    expect(gateway.applyCalls, 0);
    expect(gateway.requests.where((r) => r.contains('apply')), isEmpty);
  });

  test('loopback-only gateway shows its own failure', () async {
    gateway.mode = FakeGitMode.localOnly;
    await controller.open('http://192.168.0.40:8082');
    expect(controller.load, KovaGitLoad.failed);
    expect(controller.failure!.kind, KovaGitFailure.localOnly);
    expect(controller.failure!.message, KovaGitText.localOnly);
    gateway.mode = FakeGitMode.normal;
    await controller.refresh();
    expect(controller.load, KovaGitLoad.ready);
  });

  test('an address the policy refuses never reaches the network', () async {
    await controller.open('http://example.com:8082');
    expect(controller.load, KovaGitLoad.failed);
    expect(controller.failure!.kind, KovaGitFailure.transport);
    expect(gateway.requests, isEmpty);
    final preview = await controller.preview(
      const KovaGitPlanRequest.switchTo('master'),
    );
    expect(preview.failure, isNotNull);
  });

  test('a slow refresh is replaced by a newer one', () async {
    await controller.open('http://127.0.0.1:8082');
    gateway.hold = Completer<void>();
    final slow = controller.refresh();
    expect(controller.load, KovaGitLoad.loading);
    gateway
      ..hold!.complete()
      ..hold = null
      ..dirty = true;
    final fresh = controller.refresh();
    await Future.wait([slow, fresh]);
    expect(controller.load, KovaGitLoad.ready);
    expect(controller.status!.dirty, isTrue);
  });

  test('dispose during a load is quiet', () async {
    gateway.hold = Completer<void>();
    final opening = controller.open('http://127.0.0.1:8082');
    controller.dispose();
    gateway.hold!.complete();
    await opening;
    expect(gateway.closed, isTrue);
    // tearDown disposes again; make that a no-op by replacing the controller.
    controller = KovaGitController(clientFactory: (_) => null);
  });
}
