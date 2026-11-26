// In-memory kovapilot gateway Git API for tests and captures. It follows the
// gateway's behaviour at kovapilot master-jh@7cc3b3280
// (openpilot/kovapilot/gateway/{app.py,git_maintenance.py}): origin refs only,
// HEAD history pages, switch/reset previews with reachability checks,
// apply -> 403 git_mutation_disabled unless [FakeKovaGitGateway.applyEnabled]
// (then the kovapilot master@bccedd3ab apply: same preview again, digest
// check, 202 with the queued maintenance entry), the kovapilot master
// device restart (`restartEnabled` in status, POST /v1/device/restart -> 202
// or 403 restart_blocked; null [FakeKovaGitGateway.restartEnabled] is a
// gateway without it), and the loopback-only 403.
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

  /// The comma allows apply (registered phone, offroad, updater idle).
  bool applyEnabled = false;

  /// `mutationBlock` while [applyEnabled] is false (null like the older
  /// gateway).
  String? mutationBlock;

  /// The comma takes a restart (car off, registered phone). Null: a
  /// kovapilot without the restart API (no field, 404).
  bool? restartEnabled;
  int restartCalls = 0;

  /// After a taken restart, this many requests fail (the comma is away);
  /// then it is back, on the staged commit when one was staged. 0 keeps it
  /// answering as if it never went away.
  int restartDownRequests = 3;
  int _away = -1;

  /// The last apply request as the gateway stores it (with `phase`).
  Map<String, Object?>? maintenance;
  final List<Map<String, dynamic>> applies = [];

  bool get pending =>
      maintenance != null &&
      const {'queued', 'staged'}.contains(maintenance!['phase']);

  bool get _mutationEnabled => applyEnabled && !pending;

  Map<String, Object?>? _describe() {
    final m = maintenance;
    if (m == null) return null;
    return {
      for (final key in const ['phase', 'branch', 'commit', 'reason'])
        if (m.containsKey(key)) key: m[key],
    };
  }

  /// The updater finished downloading.
  void stage() => maintenance = {...?maintenance, 'phase': 'staged'};

  /// The updater stopped with [reason].
  void failApply(String reason) =>
      maintenance = {...?maintenance, 'phase': 'failed', 'reason': reason};

  /// The comma started again on the staged commit.
  void install() {
    final m = maintenance!;
    head = commits[m['commit']]!;
    branch = m['branch'] as String;
    upstream = 'origin/$branch';
    maintenance = {...m, 'phase': 'installed'};
  }

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
    if (_away > 0) {
      _away--;
      throw const SocketException('comma restarting');
    }
    if (_away == 0) {
      _away = -1;
      if (maintenance?['phase'] == 'staged') install();
    }
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
    'dirty': pending || dirty,
    if (pending || !dirtyKnown) 'dirtyKnown': false,
    'updaterState': updaterState,
    'mutationEnabled': _mutationEnabled,
    if (!_mutationEnabled && (mutationBlock != null || applyEnabled))
      'mutationBlock': mutationBlock ?? 'offroadOrUpdaterBusy',
    'maintenance': ?_describe(),
    if (restartEnabled != null)
      'restartEnabled': restartEnabled! && maintenance?['phase'] != 'queued',
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
    if (uri.path == '/v1/device/restart' && restartEnabled != null) {
      restartCalls++;
      if (!restartEnabled! || maintenance?['phase'] == 'queued') {
        return _error(
          403,
          'restart_blocked',
          'restart requires authorized access while offroad and not finalizing an update',
        );
      }
      if (restartDownRequests > 0) _away = restartDownRequests;
      return _json(202, {'restarting': true});
    }
    if (uri.path == '/v1/git/apply') {
      applyCalls++;
      if (!_mutationEnabled) {
        return _error(
          403,
          'git_mutation_disabled',
          'offroad maintenance requires authorized access and an idle updater',
        );
      }
      return _apply(body);
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
    final plan = _plan(operation, json['branch'], json['commit']);
    if (plan == null) {
      return _error(
        400,
        'invalid_git_request',
        'invalid Git parameters or target',
      );
    }
    return _json(200, plan);
  }

  KovaHttpResponse _apply(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return _error(400, 'invalid_git_request', 'invalid Git parameters');
    }
    if (json is! Map<String, dynamic> ||
        json.keys.any(
          (k) => !const {
            'operation',
            'branch',
            'commit',
            'planDigest',
          }.contains(k),
        ) ||
        json['planDigest'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['planDigest'] as String)) {
      return _error(400, 'invalid_git_request', 'invalid Git parameters');
    }
    applies.add(json);
    final plan = _plan(json['operation'], json['branch'], json['commit']);
    if (plan == null) {
      return _error(400, 'invalid_git_request', 'invalid Git parameters');
    }
    if (plan['dirty'] == true || plan['dirtyKnown'] == false) {
      return _error(
        403,
        'git_apply_blocked',
        'the updater is busy or the working tree is not known and clean',
      );
    }
    if (plan['planDigest'] != json['planDigest']) {
      return _error(
        409,
        'git_plan_changed',
        'refresh the preview before applying',
      );
    }
    if (plan['operation'] == 'reset' && plan['branch'] != branch) {
      return _error(
        403,
        'git_apply_blocked',
        'reset must stay on the installed branch',
      );
    }
    maintenance = {
      for (final key in const [
        'operation',
        'branch',
        'commit',
        'branchHead',
        'beforeHead',
        'beforeBranch',
      ])
        key: plan[key],
      'phase': 'queued',
    };
    return _json(202, {'maintenance': _describe()});
  }

  /// The gateway's preview, or null for a request it refuses with 400.
  Map<String, Object?>? _plan(
    Object? operation,
    Object? branchName,
    Object? requested,
  ) {
    final target = origin[branchName];
    if (target == null) return null;
    FakeGitCommit commit;
    if (operation == 'switch' && requested == null) {
      commit = target;
    } else if (operation == 'reset' &&
        requested is String &&
        RegExp(r'^[0-9a-f]{40}$').hasMatch(requested) &&
        commits.containsKey(requested) &&
        target.ancestry().any((c) => c.sha == requested)) {
      commit = commits[requested]!;
    } else {
      return null;
    }
    final plan = <String, Object?>{
      'operation': operation,
      'branch': branchName,
      'commit': commit.sha,
      'branchHead': target.sha,
      'beforeHead': head.sha,
      'beforeBranch': branch,
      'dirty': pending || dirty,
      if (pending || !dirtyKnown) 'dirtyKnown': false,
      'requiresRestart': true,
      'mutationEnabled': _mutationEnabled,
      'changedFileCount': changedFiles(head, commit),
    };
    plan['planDigest'] = fakeSha(jsonEncode(plan), length: 64);
    return plan;
  }

  @override
  void close() => closed = true;
}
