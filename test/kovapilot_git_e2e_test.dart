// End-to-end Git maintenance test against kovapilot's real gateway app.
//
// Skipped unless KOVA_E2E_GIT_HOOK points at a hook that starts/stops the
// gateway with a fixture repository (tool/e2e/kovapilot_git_gateway_hook.sh).
// Run on the worker:
//
//   KOVAPILOT_DIR=~/kova/wt/<kovapilot master-jh checkout> \
//   KOVA_E2E_GIT_HOOK=tool/e2e/kovapilot_git_gateway_hook.sh \
//   KOVA_E2E_MOUNT=~/kova KOVA_E2E_PYTHON=~/kova/kovapilot/.venv/bin/python \
//   KOVA_E2E_PYTHONPATH=~/kova/env/gateway-overlay \
//   flutter test test/kovapilot_git_e2e_test.dart
//
// The gateway binds 127.0.0.1 and refuses any other Host or an Origin
// header, which is exactly what a phone on Wi-Fi would hit; the Host test
// below shows how the app reports it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

final String? _hook = Platform.environment['KOVA_E2E_GIT_HOOK'];
final int _port =
    int.tryParse(Platform.environment['KOVA_E2E_GIT_PORT'] ?? '') ?? 18083;
final String _origin = 'http://127.0.0.1:$_port';

Future<String> hook(List<String> args) async {
  final result = await Process.run('bash', [_hook!, ...args]);
  if (result.exitCode != 0) {
    fail(
      'hook ${args.join(' ')} failed (${result.exitCode}): ${result.stdout}\n${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}

KovaGitClient _client({KovaParamsTransport? transport}) =>
    KovaGitClient.tryCreate(_origin, transport: transport)!;

Future<String> _git(String repo, List<String> args) async {
  final result = await Process.run('git', ['-C', repo, ...args]);
  if (result.exitCode != 0) fail('git ${args.join(' ')}: ${result.stderr}');
  return (result.stdout as String).trim();
}

/// Sends what the typed client never builds.
Future<(int, Map<String, dynamic>)> _raw(
  String method,
  String path, {
  Object? body,
  Map<String, String> headers = const {},
}) async {
  final http = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final request = await http.openUrl(method, Uri.parse('$_origin$path'));
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    return (response.statusCode, jsonDecode(text) as Map<String, dynamic>);
  } finally {
    http.close(force: true);
  }
}

/// dart:io transport that sends the Host a phone would send when it reaches
/// the comma by its Wi-Fi address.
class _PhoneHostTransport implements KovaParamsTransport {
  _PhoneHostTransport(this.host);
  final String host;
  final HttpClient _http = HttpClient()..findProxy = (_) => 'DIRECT';

  Future<KovaHttpResponse> _send(
    HttpClientRequest request, [
    String? body,
  ]) async {
    request.headers.host = host;
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    return KovaHttpResponse(
      response.statusCode,
      await utf8.decodeStream(response),
    );
  }

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async =>
      _send(await _http.getUrl(uri)).timeout(timeout);

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async => _send(await _http.postUrl(uri), body).timeout(timeout);

  @override
  void close() => _http.close(force: true);
}

void main() {
  final skip = _hook == null
      ? 'KOVA_E2E_GIT_HOOK not set (real gateway Git e2e)'
      : null;

  group('Git maintenance via kovapilot gateway (fixture repository)', () {
    late String repo;
    late String startHead;

    setUpAll(() async {
      await hook(['reset']);
      await hook(['start']);
      repo = await hook(['repo']);
      startHead = await _git(repo, ['rev-parse', 'HEAD']);
    });
    tearDownAll(() async {
      await hook(['slow', 'off']);
      await hook(['stop']);
    });

    test('status', () async {
      final client = _client();
      addTearDown(client.close);
      final status = await client.status();
      expect(status.branch, 'master');
      expect(status.upstream, 'origin/master');
      expect(status.upstreamBranch, 'master');
      expect(status.head, startHead);
      expect(status.dirty, isFalse);
      expect(status.updaterState, 'idle');
      expect(status.mutationEnabled, isFalse);
    });

    test('branches are origin refs only, without origin/HEAD', () async {
      final client = _client();
      addTearDown(client.close);
      final branches = await client.branches();
      expect(branches.map((b) => b.name).toSet(), {
        'master',
        'release/stable',
        'feature/longitudinal-shadow',
        'feature/ccnc-display-sync',
      });
      final master = branches.firstWhere((b) => b.name == 'master');
      expect(master.commit, startHead);
      expect(
        branches.firstWhere((b) => b.name == 'release/stable').commit,
        await _git(repo, ['rev-parse', 'origin/master~8']),
      );
    });

    test('history pages through the controller', () async {
      final controller = KovaGitController(pageSize: 10);
      addTearDown(controller.dispose);
      await controller.open(_origin);
      expect(controller.load, KovaGitLoad.ready);
      expect(controller.log, hasLength(10));
      expect(controller.log.first.commit, startHead);
      expect(
        controller.log.first.subject,
        'feat(gateway): updater state in Git status',
      );
      expect(controller.log.first.authorTime, isNotNull);
      while (controller.hasMoreLog) {
        await controller.loadMore();
        expect(controller.logFailure, isNull);
      }
      expect(controller.log, hasLength(25));
      expect(
        controller.log.last.subject,
        'chore: start kovapilot from upstream openpilot',
      );
      expect(controller.log.last.parents, isEmpty);
      expect(
        controller.log.map((e) => e.subject),
        contains('fix(ui): 설정 화면 문구를 쉬운 말로 정리'),
      );
    });

    test('switch preview', () async {
      final client = _client();
      addTearDown(client.close);
      final shadowHead = await _git(repo, [
        'rev-parse',
        'origin/feature/longitudinal-shadow',
      ]);
      final plan = await client.plan(
        const KovaGitPlanRequest.switchTo('feature/longitudinal-shadow'),
      );
      expect(plan.operation, KovaGitOperation.switchBranch);
      expect(plan.commit, shadowHead);
      expect(plan.branchHead, shadowHead);
      expect(plan.beforeHead, startHead);
      expect(plan.beforeBranch, 'master');
      expect(plan.dirty, isFalse);
      expect(plan.requiresRestart, isTrue);
      expect(plan.mutationEnabled, isFalse);
      final changed = await _git(repo, [
        'diff',
        '--name-only',
        startHead,
        shadowHead,
      ]);
      expect(plan.changedFileCount, changed.split('\n').length);
      expect(plan.planDigest, matches(RegExp(r'^[0-9a-f]{64}$')));

      final same = await client.plan(
        const KovaGitPlanRequest.switchTo('master'),
      );
      expect(same.isNoOp, isTrue);

      // Operation-specific alias.
      final alias = await _raw(
        'POST',
        '/v1/git/switch',
        body: {'branch': 'release/stable'},
      );
      expect(alias.$1, 200);
      expect(alias.$2['operation'], 'switch');
    });

    test('reset preview and refused targets', () async {
      final client = _client();
      addTearDown(client.close);
      final older = await _git(repo, ['rev-parse', 'HEAD~5']);
      final plan = await client.plan(
        KovaGitPlanRequest.resetTo(branch: 'master', commit: older),
      );
      expect(plan.operation, KovaGitOperation.reset);
      expect(plan.commit, older);
      expect(plan.branchHead, startHead);
      expect(plan.behindBranchHead, isTrue);
      expect(plan.changedFileCount, greaterThan(0));

      // Newer than release/stable: outside that branch's history.
      await expectLater(
        client.plan(
          KovaGitPlanRequest.resetTo(
            branch: 'release/stable',
            commit: startHead,
          ),
        ),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.invalidRequest)
              .having((e) => e.statusCode, 'status', 400)
              .having((e) => e.code, 'code', 'invalid_git_request')
              .having((e) => e.message, 'message', KovaGitText.invalidRequest),
        ),
      );
      // A full SHA that is not a commit at all.
      await expectLater(
        client.plan(
          KovaGitPlanRequest.resetTo(branch: 'master', commit: 'f' * 40),
        ),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.invalidRequest,
          ),
        ),
      );
      await expectLater(
        client.plan(
          const KovaGitPlanRequest.switchTo('feature/does-not-exist'),
        ),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.invalidRequest,
          ),
        ),
      );
      // Shapes the typed client never sends.
      for (final body in <Object>[
        {
          'operation': 'reset',
          'branch': 'master',
          'commit': older.substring(0, 9),
        },
        {'operation': 'switch', 'branch': 'master', 'commit': older},
        {
          'operation': 'reset',
          'branch': 'master',
          'commit': older,
          'force': true,
        },
        {'operation': 'checkout', 'branch': 'master'},
        '{not-json',
      ]) {
        final (status, json) = await _raw('POST', '/v1/git/plan', body: body);
        expect(status, 400, reason: '$body');
        expect(json['error']['code'], 'invalid_git_request');
      }
      for (final query in [
        'limit=0',
        'limit=101',
        'cursor=-1',
        'cursor=10001',
        'limit=x',
      ]) {
        final (status, json) = await _raw('GET', '/v1/git/log?$query');
        expect(status, 400, reason: query);
        expect(json['error']['code'], 'invalid_git_request');
      }
    });

    test(
      'apply is refused with 403 and the checkout does not change',
      () async {
        final client = _client();
        addTearDown(client.close);
        final plan = await client.plan(
          const KovaGitPlanRequest.switchTo('feature/ccnc-display-sync'),
        );
        await expectLater(
          client.apply(plan.planDigest),
          throwsA(
            isA<KovaGitException>()
                .having((e) => e.kind, 'kind', KovaGitFailure.mutationDisabled)
                .having((e) => e.statusCode, 'status', 403)
                .having((e) => e.code, 'code', 'git_mutation_disabled')
                .having((e) => e.message, 'message', '콤마에서 아직 바꾸기를 허용하지 않아요.'),
          ),
        );
        expect(await _git(repo, ['rev-parse', 'HEAD']), startHead);
        expect(await _git(repo, ['symbolic-ref', '--short', 'HEAD']), 'master');
        expect(await _git(repo, ['status', '--porcelain']), isEmpty);
      },
    );

    test('dirty checkout shows in status and previews', () async {
      await hook(['dirty', 'on']);
      addTearDown(() => hook(['dirty', 'off']));
      final client = _client();
      addTearDown(client.close);
      expect((await client.status()).dirty, isTrue);
      final plan = await client.plan(
        const KovaGitPlanRequest.switchTo('release/stable'),
      );
      expect(plan.dirty, isTrue);
    });

    test('updater state text', () async {
      await hook(['updater', 'checking...']);
      addTearDown(() => hook(['updater', 'idle']));
      final client = _client();
      addTearDown(client.close);
      expect((await client.status()).updaterState, 'checking...');
      await hook(['updater', '']);
      expect((await client.status()).updaterState, isNull);
    });

    test(
      'a phone-style Host or an Origin header gets local_client_required',
      () async {
        final phone = _client(
          transport: _PhoneHostTransport('192.168.0.40:$_port'),
        );
        addTearDown(phone.close);
        await expectLater(
          phone.status(),
          throwsA(
            isA<KovaGitException>()
                .having((e) => e.kind, 'kind', KovaGitFailure.localOnly)
                .having((e) => e.statusCode, 'status', 403)
                .having((e) => e.code, 'code', 'local_client_required')
                .having(
                  (e) => e.message,
                  'message',
                  '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.',
                ),
          ),
        );
        final named = _client(
          transport: _PhoneHostTransport('comma.local:$_port'),
        );
        addTearDown(named.close);
        await expectLater(
          named.plan(const KovaGitPlanRequest.switchTo('master')),
          throwsA(
            isA<KovaGitException>().having(
              (e) => e.kind,
              'kind',
              KovaGitFailure.localOnly,
            ),
          ),
        );
        final origin = await _raw(
          'GET',
          '/v1/git/status',
          headers: {'Origin': 'http://192.168.0.40'},
        );
        expect(origin.$1, 403);
        expect(origin.$2['error']['code'], 'local_client_required');
      },
    );

    test('a missing checkout is git_unavailable (503)', () async {
      await hook(['hide']);
      addTearDown(() => hook(['show']));
      final client = _client();
      addTearDown(client.close);
      await expectLater(
        client.status(),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.unavailable)
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.code, 'code', 'git_unavailable'),
        ),
      );
    });

    test('a second request while one runs is git_busy (503)', () async {
      await hook(['slow', 'on']);
      addTearDown(() => hook(['slow', 'off']));
      final first = _client();
      final second = _client();
      addTearDown(first.close);
      addTearDown(second.close);
      final running = first.branches();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await expectLater(
        second.status(),
        throwsA(
          isA<KovaGitException>()
              .having((e) => e.kind, 'kind', KovaGitFailure.busy)
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.code, 'code', 'git_busy')
              .having((e) => e.message, 'message', KovaGitText.busy),
        ),
      );
      expect(await running, hasLength(4));
    });

    test('the loopback-only bind does not answer on a LAN address', () async {
      final lan = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback)
          .map((a) => a.address)
          .where(
            (a) =>
                a.startsWith('10.') ||
                a.startsWith('192.168.') ||
                a.startsWith('172.'),
          )
          .toList();
      if (lan.isEmpty) {
        markTestSkipped('no private IPv4 interface');
        return;
      }
      final client = KovaGitClient.tryCreate('http://${lan.first}:$_port')!;
      addTearDown(client.close);
      await expectLater(
        client.status(),
        throwsA(
          isA<KovaGitException>().having(
            (e) => e.kind,
            'kind',
            KovaGitFailure.transport,
          ),
        ),
      );
    });

    test('nothing on the comma changed', () async {
      expect(await _git(repo, ['rev-parse', 'HEAD']), startHead);
      expect(await _git(repo, ['symbolic-ref', '--short', 'HEAD']), 'master');
      expect(await _git(repo, ['status', '--porcelain']), isEmpty);
    });
  }, skip: skip);
}
