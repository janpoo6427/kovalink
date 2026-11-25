// Typed view of the kovapilot gateway Git maintenance API
// (kovapilot `docs/kovapilot/KOVALINK_GATEWAY.md`, contract at
// `master-jh@7cc3b3280`). The gateway only inspects the device checkout and
// previews a branch switch or a reset; `mutationEnabled` stays false and
// `POST /v1/git/apply` answers 403 until authenticated updater integration
// exists. Nothing here changes the device.

final RegExp _fullSha = RegExp(r'^[0-9a-f]{40}$');
final RegExp _digest = RegExp(r'^[0-9a-f]{64}$');

/// True for a full 40-character lowercase commit SHA, the only form the
/// gateway accepts for a reset target.
bool isFullCommitSha(Object? value) =>
    value is String && _fullSha.hasMatch(value);

/// Short form shown on screen; the full SHA is what gets copied.
String shortCommit(String sha, {int length = 9}) =>
    sha.length <= length ? sha : sha.substring(0, length);

/// A Git answer that does not match the contract. The reason is for
/// developers and tests; screens show one plain line instead.
class KovaGitFormatException implements Exception {
  const KovaGitFormatException(this.reason);
  final String reason;

  @override
  String toString() => 'KovaGitFormatException: $reason';
}

Map<String, dynamic> _object(Object? json, String what) {
  if (json is Map<String, dynamic>) return json;
  if (json is Map) return json.cast<String, dynamic>();
  throw KovaGitFormatException('$what must be a JSON object');
}

String _sha(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (!isFullCommitSha(value)) {
    throw KovaGitFormatException('$key must be a full commit SHA');
  }
  return value as String;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw KovaGitFormatException('$key must be a string');
  return value.isEmpty ? null : value;
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw KovaGitFormatException('$key must be a non-empty string');
  }
  return value;
}

bool _bool(Map<String, dynamic> json, String key, {bool? fallback}) {
  final value = json[key];
  if (value is bool) return value;
  if (value == null && fallback != null) return fallback;
  throw KovaGitFormatException('$key must be a boolean');
}

/// `GET /v1/git/status`.
class KovaGitStatus {
  const KovaGitStatus({
    required this.head,
    this.branch,
    this.upstream,
    this.dirty = false,
    this.updaterState,
    this.mutationEnabled = false,
  });

  factory KovaGitStatus.fromJson(Object? json) {
    final map = _object(json, 'status');
    // UpdaterState is a free-form Params string on the device; anything that
    // is not a string is treated as unknown rather than failing the screen.
    final updater = map['updaterState'];
    return KovaGitStatus(
      head: _sha(map, 'head'),
      branch: _optionalString(map, 'branch'),
      upstream: _optionalString(map, 'upstream'),
      dirty: _bool(map, 'dirty'),
      updaterState: updater is String && updater.trim().isNotEmpty
          ? updater.trim()
          : null,
      mutationEnabled: _bool(map, 'mutationEnabled', fallback: false),
    );
  }

  /// Current local branch, or null when HEAD is detached.
  final String? branch;
  final String head;

  /// Tracked remote branch such as `origin/master`, or null.
  final String? upstream;

  /// True when the device checkout has modified or untracked files.
  final bool dirty;
  final String? updaterState;
  final bool mutationEnabled;

  bool get detached => branch == null;

  /// The tracked branch without its `origin/` prefix (the name used by
  /// `/v1/git/branches` and plan requests), or null.
  String? get upstreamBranch {
    final value = upstream;
    if (value == null || !value.startsWith('origin/')) return null;
    final name = value.substring('origin/'.length);
    return name.isEmpty ? null : name;
  }
}

/// One entry of `GET /v1/git/branches`: a fetched `origin/<name>` ref.
class KovaGitBranch {
  const KovaGitBranch({required this.name, required this.commit});

  factory KovaGitBranch.fromJson(Object? json) {
    final map = _object(json, 'branch');
    return KovaGitBranch(
      name: _string(map, 'name'),
      commit: _sha(map, 'commit'),
    );
  }

  final String name;
  final String commit;

  @override
  bool operator ==(Object other) =>
      other is KovaGitBranch && other.name == name && other.commit == commit;

  @override
  int get hashCode => Object.hash(name, commit);

  @override
  String toString() => 'KovaGitBranch($name ${shortCommit(commit)})';
}

List<KovaGitBranch> parseKovaGitBranches(Object? json) {
  final map = _object(json, 'branches response');
  final list = map['branches'];
  if (list is! List) {
    throw const KovaGitFormatException('branches must be a list');
  }
  return [for (final item in list) KovaGitBranch.fromJson(item)];
}

/// One commit of `GET /v1/git/log` (current HEAD history).
class KovaGitLogEntry {
  const KovaGitLogEntry({
    required this.commit,
    required this.parents,
    required this.subject,
    this.authorTime,
  });

  factory KovaGitLogEntry.fromJson(Object? json) {
    final map = _object(json, 'log entry');
    final parents = map['parents'];
    if (parents is! List || !parents.every(isFullCommitSha)) {
      throw const KovaGitFormatException('parents must be commit SHAs');
    }
    final subject = map['subject'];
    if (subject is! String) {
      throw const KovaGitFormatException('subject must be a string');
    }
    final time = map['authorTime'];
    return KovaGitLogEntry(
      commit: _sha(map, 'commit'),
      parents: List.unmodifiable(parents.cast<String>()),
      subject: subject,
      authorTime: time is String ? DateTime.tryParse(time) : null,
    );
  }

  final String commit;
  final List<String> parents;
  final String subject;

  /// Author time from the device, or null when missing or unreadable.
  final DateTime? authorTime;

  bool get isMerge => parents.length > 1;
}

/// A page of history plus the cursor for the next page (null at the end).
class KovaGitLogPage {
  const KovaGitLogPage({required this.entries, this.nextCursor});

  factory KovaGitLogPage.fromJson(Object? json) {
    final map = _object(json, 'log response');
    final list = map['entries'];
    if (list is! List) {
      throw const KovaGitFormatException('entries must be a list');
    }
    final next = map['nextCursor'];
    if (next != null && (next is! int || next < 0)) {
      throw const KovaGitFormatException('nextCursor must be an offset');
    }
    return KovaGitLogPage(
      entries: [for (final item in list) KovaGitLogEntry.fromJson(item)],
      nextCursor: next as int?,
    );
  }

  final List<KovaGitLogEntry> entries;
  final int? nextCursor;
}

enum KovaGitOperation {
  /// Move to the head of another fetched origin branch.
  switchBranch('switch'),

  /// Go back to an exact commit inside a fetched origin branch's history.
  reset('reset');

  const KovaGitOperation(this.wireName);
  final String wireName;

  static KovaGitOperation? fromWire(Object? value) {
    for (final operation in values) {
      if (operation.wireName == value) return operation;
    }
    return null;
  }
}

/// Body of `POST /v1/git/plan`. A switch never carries a commit; a reset
/// always carries a full SHA.
class KovaGitPlanRequest {
  const KovaGitPlanRequest.switchTo(this.branch)
    : operation = KovaGitOperation.switchBranch,
      commit = null;

  const KovaGitPlanRequest.resetTo({
    required this.branch,
    required String this.commit,
  }) : operation = KovaGitOperation.reset;

  final KovaGitOperation operation;
  final String branch;
  final String? commit;

  Map<String, Object> toJson() => {
    'operation': operation.wireName,
    'branch': branch,
    'commit': ?commit,
  };
}

/// Answer of `POST /v1/git/plan`: what would change. Always a preview.
class KovaGitPlan {
  const KovaGitPlan({
    required this.operation,
    required this.branch,
    required this.commit,
    required this.branchHead,
    required this.beforeHead,
    required this.dirty,
    required this.requiresRestart,
    required this.changedFileCount,
    required this.planDigest,
    this.beforeBranch,
    this.mutationEnabled = false,
  });

  factory KovaGitPlan.fromJson(Object? json) {
    final map = _object(json, 'plan');
    final operation = KovaGitOperation.fromWire(map['operation']);
    if (operation == null) {
      throw const KovaGitFormatException('operation must be switch or reset');
    }
    final count = map['changedFileCount'];
    if (count is! int || count < 0) {
      throw const KovaGitFormatException('changedFileCount must be a count');
    }
    final digest = map['planDigest'];
    if (digest is! String || !_digest.hasMatch(digest)) {
      throw const KovaGitFormatException('planDigest must be a SHA-256 hex');
    }
    return KovaGitPlan(
      operation: operation,
      branch: _string(map, 'branch'),
      commit: _sha(map, 'commit'),
      branchHead: _sha(map, 'branchHead'),
      beforeHead: _sha(map, 'beforeHead'),
      beforeBranch: _optionalString(map, 'beforeBranch'),
      dirty: _bool(map, 'dirty'),
      requiresRestart: _bool(map, 'requiresRestart'),
      mutationEnabled: _bool(map, 'mutationEnabled', fallback: false),
      changedFileCount: count,
      planDigest: digest,
    );
  }

  final KovaGitOperation operation;
  final String branch;

  /// Target commit (the branch head for a switch).
  final String commit;
  final String branchHead;
  final String beforeHead;
  final String? beforeBranch;
  final bool dirty;
  final bool requiresRestart;
  final bool mutationEnabled;
  final int changedFileCount;
  final String planDigest;

  /// Already on the target commit: nothing would change.
  bool get isNoOp => commit == beforeHead && changedFileCount == 0;

  /// A reset to an older commit than the branch head.
  bool get behindBranchHead => commit != branchHead;
}
