import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

import 'support/fake_kova_git_gateway.dart';

class _Canned implements KovaParamsTransport {
  _Canned(this.status, this.body);
  final int status;
  final String body;
  final List<Uri> uris = [];

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async {
    uris.add(uri);
    return KovaHttpResponse(status, body);
  }

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async {
    uris.add(uri);
    return KovaHttpResponse(status, this.body);
  }

  @override
  void close() {}
}

class _Throws implements KovaParamsTransport {
  _Throws(this.error);
  final Object error;

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async => throw error;

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async => throw error;

  @override
  void close() {}
}

TypeMatcher<KovaGitException> _fails(KovaGitFailure kind, [String? message]) =>
    isA<KovaGitException>()
        .having((e) => e.kind, 'kind', kind)
        .having((e) => e.message, 'message', message ?? isNotEmpty);

void main() {
  late FakeKovaGitGateway gateway;
  late KovaGitClient client;

  setUp(() {
    gateway = FakeKovaGitGateway.sample();
    client = KovaGitClient(
      Uri.parse('http://127.0.0.1:8082'),
      transport: gateway,
    );
  });

  test('status, branches and the first history page', () async {
    final status = await client.status();
    expect(status.branch, 'master');
    expect(status.upstreamBranch, 'master');
    expect(status.head, gateway.commitOf('master').sha);
    expect(status.updaterState, 'idle');

    final branches = await client.branches();
    expect(
      branches.map((b) => b.name),
      containsAll([
        'master',
        'feature/longitudinal-shadow',
        'feature/ccnc-display-sync',
        'release/stable',
      ]),
    );

    final page = await client.log();
    expect(page.entries, hasLength(20));
    expect(page.nextCursor, 20);
    expect(page.entries.first.commit, status.head);
    final rest = await client.log(cursor: 20);
    expect(rest.entries, hasLength(10));
    expect(rest.nextCursor, isNull);
    expect(gateway.requests, contains('/v1/git/log?limit=20&cursor=20'));
  });

  test('switch and reset previews', () async {
    final switched = await client.plan(
      const KovaGitPlanRequest.switchTo('feature/longitudinal-shadow'),
    );
    expect(switched.operation, KovaGitOperation.switchBranch);
    expect(
      switched.commit,
      gateway.commitOf('feature/longitudinal-shadow').sha,
    );
    expect(switched.beforeBranch, 'master');
    expect(switched.changedFileCount, greaterThan(0));
    expect(switched.requiresRestart, isTrue);
    expect(switched.mutationEnabled, isFalse);
    expect(gateway.posts.last, {
      'operation': 'switch',
      'branch': 'feature/longitudinal-shadow',
    });

    final older = (await client.log()).entries[5].commit;
    final reset = await client.plan(
      KovaGitPlanRequest.resetTo(branch: 'master', commit: older),
    );
    expect(reset.operation, KovaGitOperation.reset);
    expect(reset.commit, older);
    expect(reset.behindBranchHead, isTrue);

    final same = await client.plan(const KovaGitPlanRequest.switchTo('master'));
    expect(same.isNoOp, isTrue);
  });

  test('a commit outside the chosen branch is refused by the comma', () async {
    final shadowOnly = gateway.commitOf('feature/longitudinal-shadow').sha;
    await expectLater(
      client.plan(
        KovaGitPlanRequest.resetTo(
          branch: 'release/stable',
          commit: shadowOnly,
        ),
      ),
      throwsA(
        _fails(KovaGitFailure.invalidRequest, KovaGitText.invalidRequest),
      ),
    );
    await expectLater(
      client.plan(const KovaGitPlanRequest.switchTo('feature/nope')),
      throwsA(_fails(KovaGitFailure.invalidRequest)),
    );
  });

  test(
    'a short reset SHA and out-of-range pages are refused before sending',
    () async {
      await expectLater(
        client.plan(
          const KovaGitPlanRequest.resetTo(
            branch: 'master',
            commit: '7cc3b3280',
          ),
        ),
        throwsA(_fails(KovaGitFailure.invalidRequest)),
      );
      await expectLater(
        client.log(limit: 0),
        throwsA(_fails(KovaGitFailure.invalidRequest)),
      );
      await expectLater(
        client.log(limit: 101),
        throwsA(_fails(KovaGitFailure.invalidRequest)),
      );
      await expectLater(
        client.log(cursor: -1),
        throwsA(_fails(KovaGitFailure.invalidRequest)),
      );
      await expectLater(
        client.log(cursor: 10001),
        throwsA(_fails(KovaGitFailure.invalidRequest)),
      );
      expect(gateway.requests, isEmpty);
    },
  );

  test('apply is refused with 403 and nothing changes', () async {
    final plan = await client.plan(
      const KovaGitPlanRequest.switchTo('release/stable'),
    );
    await expectLater(
      client.apply(plan.planDigest),
      throwsA(
        _fails(KovaGitFailure.mutationDisabled, KovaGitText.mutationDisabled),
      ),
    );
    expect(gateway.applyCalls, 1);
    expect((await client.status()).head, gateway.commitOf('master').sha);
  });

  test(
    'loopback-only gateway: found, but phones are not allowed yet',
    () async {
      gateway.mode = FakeGitMode.localOnly;
      await expectLater(
        client.status(),
        throwsA(
          _fails(KovaGitFailure.localOnly, '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.')
              .having((e) => e.statusCode, 'status', 403)
              .having((e) => e.code, 'code', 'local_client_required')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    },
  );

  test('busy, unavailable, old gateway, timeout and no connection', () async {
    final cases = {
      FakeGitMode.busy: (KovaGitFailure.busy, KovaGitText.busy, true),
      FakeGitMode.unavailable: (
        KovaGitFailure.unavailable,
        KovaGitText.unavailable,
        true,
      ),
      FakeGitMode.oldGateway: (
        KovaGitFailure.unsupported,
        KovaGitText.unsupported,
        false,
      ),
      FakeGitMode.timeout: (KovaGitFailure.timeout, KovaGitText.timeout, true),
      FakeGitMode.down: (KovaGitFailure.transport, KovaGitText.transport, true),
    };
    for (final MapEntry(key: mode, value: (kind, message, retryable))
        in cases.entries) {
      gateway.mode = mode;
      await expectLater(
        client.branches(),
        throwsA(
          _fails(
            kind,
            message,
          ).having((e) => e.retryable, 'retryable', retryable),
        ),
        reason: '$mode',
      );
    }
  });

  test('a 200 that is not the contract is a format failure', () async {
    for (final body in ['not json', '{"branches": "x"}', '[]']) {
      final c = KovaGitClient(
        Uri.parse('http://127.0.0.1:8082'),
        transport: _Canned(200, body),
      );
      await expectLater(
        c.branches(),
        throwsA(_fails(KovaGitFailure.format, KovaGitText.format)),
      );
    }
    final apply200 = KovaGitClient(
      Uri.parse('http://127.0.0.1:8082'),
      transport: _Canned(200, '{}'),
    );
    await expectLater(
      apply200.apply('0' * 64),
      throwsA(_fails(KovaGitFailure.format)),
    );
  });

  test('unknown error codes and bodies stay generic', () async {
    for (final (status, body) in [
      (500, '{"error": {"code": "boom", "message": "Traceback ..."}}'),
      (403, '{"error": {"code": "update_forbidden", "message": "x"}}'),
      (502, '<html>bad gateway</html>'),
    ]) {
      final c = KovaGitClient(
        Uri.parse('http://127.0.0.1:8082'),
        transport: _Canned(status, body),
      );
      await expectLater(
        c.status(),
        throwsA(
          _fails(
            KovaGitFailure.http,
            KovaGitText.http,
          ).having((e) => e.statusCode, 's', status),
        ),
      );
    }
  });

  test('transport exceptions', () async {
    for (final (error, kind) in [
      (TimeoutException('t'), KovaGitFailure.timeout),
      (const SocketException('refused'), KovaGitFailure.transport),
      (const HttpException('too big'), KovaGitFailure.transport),
      (const FormatException('utf8'), KovaGitFailure.format),
    ]) {
      final c = KovaGitClient(
        Uri.parse('http://127.0.0.1:8082'),
        transport: _Throws(error),
      );
      await expectLater(c.status(), throwsA(_fails(kind)), reason: '$error');
    }
  });

  test('only local addresses are used', () {
    String? error;
    expect(
      KovaGitClient.tryCreate(
        'http://example.com:8082',
        onError: (e) => error = e,
      ),
      isNull,
    );
    expect(error, isNotNull);
    final local = KovaGitClient.tryCreate('http://192.168.0.40:8082');
    expect(local, isNotNull);
    expect(local!.baseUri.toString(), 'http://192.168.0.40:8082');
    local.close();
    expect(KovaGitClient.tryCreate('http://192.168.0.40:8082/v1/git'), isNull);
  });

  test('requests go to the documented paths', () async {
    final canned = _Canned(
      503,
      '{"error": {"code": "git_busy", "message": "x"}}',
    );
    final c = KovaGitClient(
      Uri.parse('http://10.0.0.5:8082'),
      transport: canned,
    );
    for (final call in <Future<Object?> Function()>[
      c.status,
      c.branches,
      () => c.log(limit: 5, cursor: 10),
      () => c.plan(const KovaGitPlanRequest.switchTo('master')),
      () => c.apply('0' * 64),
    ]) {
      await expectLater(call(), throwsA(isA<KovaGitException>()));
    }
    expect(canned.uris.map((u) => u.toString()), [
      'http://10.0.0.5:8082/v1/git/status',
      'http://10.0.0.5:8082/v1/git/branches',
      'http://10.0.0.5:8082/v1/git/log?limit=5&cursor=10',
      'http://10.0.0.5:8082/v1/git/plan',
      'http://10.0.0.5:8082/v1/git/apply',
    ]);
  });
}
