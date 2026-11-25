// In-memory kovapilot gateway Git API for tests and captures. It follows the
// gateway's behaviour at kovapilot master-jh@7cc3b3280
// (openpilot/kovapilot/gateway/{app.py,git_maintenance.py}): origin refs only,
// HEAD history pages, switch/reset previews with reachability checks,
// apply -> 403 git_mutation_disabled, and the loopback-only 403.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_client.dart';

/// Deterministic 40-hex "SHA" for a label (not a real Git hash).
String fakeSha(String label, {int length = 40}) {
  var state = 0x811c9dc5;
  for (final unit in label.codeUnits) {
    state = ((state ^ unit) * 0x01000193) & 0xffffffff;
  }
  final out = StringBuffer();
  while (out.length < length) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    out.write((state >> 8 & 0xffff).toRadixString(16).padLeft(4, '0'));
  }
  return out.toString().substring(0, length);
}

class FakeGitCommit {
  FakeGitCommit(this.label, this.subject, this.time, this.parents, this.files)
    : sha = fakeSha(label);
  final String label;
  final String sha;
  final String subject;
  final DateTime time;
  final List<FakeGitCommit> parents;
  final Set<String> files;

  Iterable<FakeGitCommit> ancestry() sync* {
    final seen = <String>{};
    final queue = [this];
    while (queue.isNotEmpty) {
      final next = queue.removeAt(0);
      if (!seen.add(next.sha)) continue;
      yield next;
      queue.addAll(next.parents);
    }
  }
}

enum FakeGitMode {
  normal,
  localOnly,
  busy,
  unavailable,
  down,
  timeout,
  oldGateway,
}

class FakeKovaGitGateway implements KovaParamsTransport {
  FakeKovaGitGateway._(
    this.commits,
    this.origin,
    this.head, {
    this.branch,
    this.upstream,
  });

  /// The default story: master with 30 commits, a shadow-control feature
  /// branch, a display-sync feature branch and an older release branch.
  factory FakeKovaGitGateway.sample() {
    final base = DateTime.utc(2026, 11, 20, 1);
    final subjects = <String>[
      'chore: start kovapilot from upstream openpilot',
      'feat(branding): kovapilot boot logo and name',
      'feat(config): kova_params catalog and schema',
      'feat(config): persistent KovaParams runtime state',
      'feat(gateway): add loopback kova params API',
      'test(gateway): kova_params revision conflict',
      'fix(gateway): read IsOffroad from the device',
      'feat(display): onroad screen brightness modes',
      'docs: KovaLink gateway contract',
      'feat(gateway): enforce kova_params ranges and options',
      'fix(ui): 설정 화면 문구를 쉬운 말로 정리',
      'feat(longitudinal): shadow replay logging',
      'test(longitudinal): replay fixtures for shadow mode',
      'fix(car): steering icon state on CCNC',
      'feat(gateway): serve telemetry camera and git maintenance previews',
      'chore(release): bump kovapilot version',
      'fix(gateway): bounded camera signaling retries',
      'feat(ui): driver monitoring session toggle',
      'fix(params): keep KovaParams on manager restart',
      'test(gateway): telemetry stale source omission',
      'docs(gateway): Git maintenance preview contract',
      'fix(updater): log the staged commit',
      'feat(display): auto brightness at night',
      'refactor(gateway): one Git inspection at a time',
      'fix(ui): 주행 화면 속도 표시 깜박임 수정',
      'test(display): brightness mode transitions',
      'chore: update opendbc submodule',
      'fix(gateway): reject Origin headers',
      'feat(gateway): updater state in Git status',
      'merge: driver monitoring session disable',
    ];
    final commits = <String, FakeGitCommit>{};
    FakeGitCommit? previous;
    for (var i = 0; i < subjects.length; i++) {
      final commit = FakeGitCommit(
        'master-$i',
        subjects[i],
        base.add(Duration(hours: i * 4)),
        [?previous],
        {
          'openpilot/kovapilot/file_${i % 7}.py',
          if (i % 3 == 0) 'docs/notes_$i.md',
        },
      );
      commits[commit.sha] = commit;
      previous = commit;
    }
    final master = previous!;
    FakeGitCommit chain(
      String name,
      FakeGitCommit from,
      List<String> subjects,
      int hour,
    ) {
      var tip = from;
      for (var i = 0; i < subjects.length; i++) {
        tip = FakeGitCommit(
          '$name-$i',
          subjects[i],
          from.time.add(Duration(hours: hour + i)),
          [tip],
          {
            'openpilot/kovapilot/$name/part_$i.py',
            'openpilot/kovapilot/file_${i % 7}.py',
          },
        );
        commits[tip.sha] = tip;
      }
      return tip;
    }

    final masterList = master.ancestry().toList();
    final shadow = chain('shadow', masterList[2], [
      'feat(longitudinal): shadow planner output',
      'test(longitudinal): shadow planner replay',
      'fix(longitudinal): clamp shadow accel request',
    ], 2);
    final display = chain('display', master, [
      'feat(display): sync cruise icon with the cluster',
      'test(display): cluster icon sync',
    ], 3);
    final release = masterList[8];
    return FakeKovaGitGateway._(
      commits,
      {
        'master': master,
        'feature/longitudinal-shadow': shadow,
        'feature/ccnc-display-sync': display,
        'release/stable': release,
      },
      master,
      branch: 'master',
      upstream: 'origin/master',
    );
  }

  final Map<String, FakeGitCommit> commits;
  final Map<String, FakeGitCommit> origin;
  FakeGitCommit head;
  String? branch;
  String? upstream;
  bool dirty = false;
  bool dirtyKnown = true;
  String? updaterState = 'idle';
  FakeGitMode mode = FakeGitMode.normal;

  /// When set, every request waits for it (loading captures).
  Completer<void>? hold;
  final List<String> requests = [];
  final List<Map<String, dynamic>> posts = [];
  int applyCalls = 0;
  bool closed = false;

  FakeGitCommit commitOf(String branchName) => origin[branchName]!;

  /// What a branch switch on the comma leaves behind: HEAD at the head of
  /// `origin/<branchName>`, on a local branch of that name tracking it.
  void checkout(String branchName) {
    head = commitOf(branchName);
    branch = branchName;
    upstream = 'origin/$branchName';
  }

  /// A commit made on the comma only (on top of HEAD, never pushed): it is
  /// in the history but in no origin branch.
  FakeGitCommit commitOnComma(String subject) {
    final commit = FakeGitCommit(
      'comma-${commits.length}',
      subject,
      head.time.add(const Duration(hours: 1)),
      [head],
      {'openpilot/kovapilot/comma_only.py'},
    );
    commits[commit.sha] = commit;
    head = commit;
    return commit;
  }

  List<FakeGitCommit> headHistory() =>
      head.ancestry().toList()..sort((a, b) => b.time.compareTo(a.time));

  static KovaHttpResponse _json(int status, Object body) =>
      KovaHttpResponse(status, jsonEncode(body));

  static KovaHttpResponse _error(int status, String code, String message) =>
      _json(status, {
        'error': {'code': code, 'message': message},
      });

  Future<KovaHttpResponse?> _gate(Uri uri) async {
    requests.add(uri.path + (uri.hasQuery ? '?${uri.query}' : ''));
    if (hold != null) await hold!.future;
    switch (mode) {
      case FakeGitMode.down:
        throw const SocketException('connection refused');
      case FakeGitMode.timeout:
        throw TimeoutException('no answer');
      case FakeGitMode.localOnly:
        return _error(
          403,
          'local_client_required',
          'only native loopback clients are supported',
        );
      case FakeGitMode.oldGateway:
        return KovaHttpResponse(404, '404: Not Found');
      case FakeGitMode.busy:
        if (uri.path == '/v1/git/apply') return null;
        return _error(503, 'git_busy', 'repository inspection is in progress');
      case FakeGitMode.unavailable:
        if (uri.path == '/v1/git/apply') return null;
        return _error(
          503,
          'git_unavailable',
          'device repository could not be inspected',
        );
      case FakeGitMode.normal:
        return null;
    }
  }

  Map<String, Object?> statusJson() => {
    'branch': branch,
    'head': head.sha,
    'upstream': upstream,
    'dirty': dirty,
    if (!dirtyKnown) 'dirtyKnown': false,
    'updaterState': updaterState,
    'mutationEnabled': false,
  };

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async {
    final gated = await _gate(uri);
    if (gated != null) return gated;
    switch (uri.path) {
      case '/v1/git/status':
        return _json(200, statusJson());
      case '/v1/git/branches':
        return _json(200, {
          'branches': [
            for (final entry in origin.entries)
              {'name': entry.key, 'commit': entry.value.sha},
          ],
        });
      case '/v1/git/log':
        final limit = int.tryParse(uri.queryParameters['limit'] ?? '20');
        final cursor = int.tryParse(uri.queryParameters['cursor'] ?? '0');
        if (limit == null ||
            cursor == null ||
            limit < 1 ||
            limit > 100 ||
            cursor < 0 ||
            cursor > 10000) {
          return _error(
            400,
            'invalid_git_request',
            'invalid Git parameters or target',
          );
        }
        final history = headHistory();
        final page = history.skip(cursor).take(limit + 1).toList();
        return _json(200, {
          'entries': [
            for (final c in page.take(limit))
              {
                'commit': c.sha,
                'parents': [for (final p in c.parents) p.sha],
                'authorTime':
                    '${c.time.toUtc().toIso8601String().split('.').first}+00:00',
                'subject': c.subject,
              },
          ],
          'nextCursor': page.length > limit ? cursor + limit : null,
        });
      default:
        return KovaHttpResponse(404, '404: Not Found');
    }
  }

  int changedFiles(FakeGitCommit from, FakeGitCommit to) {
    final a = {for (final c in from.ancestry()) c.sha};
    final b = {for (final c in to.ancestry()) c.sha};
    final files = <String>{};
    for (final sha in a.difference(b).union(b.difference(a))) {
      files.addAll(commits[sha]!.files);
    }
    return files.length;
  }

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async {
    final gated = await _gate(uri);
    if (gated != null) return gated;
    if (uri.path == '/v1/git/apply') {
      applyCalls++;
      return _error(
        403,
        'git_mutation_disabled',
        'authenticated updater integration is unavailable',
      );
    }
    final action = switch (uri.path) {
      '/v1/git/plan' => 'plan',
      '/v1/git/switch' => 'switch',
      '/v1/git/reset' => 'reset',
      _ => null,
    };
    if (action == null) return KovaHttpResponse(404, '404: Not Found');
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    if (json is! Map<String, dynamic> ||
        json.keys.any(
          (k) => !const {'operation', 'branch', 'commit'}.contains(k),
        )) {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    posts.add(json);
    final operation = json['operation'] ?? action;
    if (action != 'plan' && operation != action) {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    final target = origin[json['branch']];
    if (target == null) {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    FakeGitCommit commit;
    final requested = json['commit'];
    if (operation == 'switch' && requested == null) {
      commit = target;
    } else if (operation == 'reset' &&
        requested is String &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(requested) &&
        commits.containsKey(requested) &&
        target.ancestry().any((c) => c.sha == requested)) {
      commit = commits[requested]!;
    } else {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    final plan = <String, Object?>{
      'operation': operation,
      'branch': json['branch'],
      'commit': commit.sha,
      'branchHead': target.sha,
      'beforeHead': head.sha,
      'beforeBranch': branch,
      'dirty': dirty,
      'requiresRestart': true,
      'mutationEnabled': false,
      'changedFileCount': changedFiles(head, commit),
    };
    plan['planDigest'] = fakeSha(jsonEncode(plan), length: 64);
    return _json(200, plan);
  }

  @override
  void close() => closed = true;
}
