// State for the kovapilot version screen: current checkout, fetched origin
// branches, HEAD history pages and switch/reset previews. Read-only; the
// apply step is never sent.
//
// A reset only ever goes back inside the branch the comma is on: the
// history the gateway gives is that branch's (HEAD), so a commit of another
// branch is reached by switching to that branch first and picking from its
// history after the next read.
import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

typedef KovaGitClientFactory = KovaGitClient? Function(String endpoint);

enum KovaGitLoad { idle, loading, ready, failed }

/// Why the history cannot be used for a reset right now.
enum KovaGitResetBlock {
  /// HEAD is detached: there is no current branch to stay inside.
  detached,

  /// The current branch is not among the fetched origin branches, so the
  /// comma has nothing to check a reset against.
  notFetched,
}

/// Words for the branch-first rule. Kept together so the screen and the
/// tests agree.
abstract final class KovaGitBranchText {
  /// A reset preview refused with 400: the commit is not in [branch]'s
  /// history on the comma (for example a commit made only on the comma).
  static String notInBranch(String branch) =>
      '이 커밋은 ‘$branch’ 브랜치 기록에 없어서 되돌릴 수 없어요.';

  static const detached = '지금 콤마는 브랜치 없이 커밋에 고정돼 있어서 여기서 되돌릴 수 없어요.';

  static String notFetched(String branch) =>
      '지금 브랜치 ‘$branch’는 콤마가 받아 둔 브랜치 목록에 없어서 여기서 되돌릴 수 없어요.';

  static const switchFirst = '먼저 브랜치로 바꿔 주세요.';

  static String resetInside(String branch) => '지금 브랜치 ‘$branch’ 안에서 되돌려요.';

  static String pickAfterSwitch(String branch) =>
      '바꾼 뒤 ‘$branch’의 커밋 기록에서 되돌릴 커밋을 고를 수 있어요.';

  static const otherBranchCommits =
      '다른 브랜치의 커밋으로 가려면 먼저 그 브랜치로 바꾼 뒤, 그 브랜치의 커밋 기록에서 골라요.';

  static String historyTitle(String? branch) =>
      branch == null ? '커밋 기록' : '‘$branch’ 커밋 기록';

  static String historyOnly(String branch) => '지금 브랜치 ‘$branch’의 커밋만 보여요.';

  static const historyDetached = '지금 고정된 커밋까지의 기록이에요.';

  static const showBranches = '브랜치 목록 보기';
}

/// Result of a preview: either a plan or a failure line.
class KovaGitPreview {
  const KovaGitPreview.plan(KovaGitPlan this.plan) : failure = null;
  const KovaGitPreview.failed(KovaGitException this.failure) : plan = null;
  final KovaGitPlan? plan;
  final KovaGitException? failure;
}

class KovaGitController extends ChangeNotifier {
  KovaGitController({KovaGitClientFactory? clientFactory, this.pageSize = 20})
    : _clientFactory = clientFactory ?? KovaGitClient.tryCreate;

  final KovaGitClientFactory _clientFactory;
  final int pageSize;

  KovaGitClient? _client;
  String? _endpoint;
  int _generation = 0;
  bool _disposed = false;

  KovaGitLoad load = KovaGitLoad.idle;
  KovaGitException? failure;
  KovaGitStatus? status;
  List<KovaGitBranch> branches = const [];
  List<KovaGitLogEntry> log = const [];
  int? nextCursor;
  bool loadingMore = false;
  KovaGitException? logFailure;
  String query = '';

  String? get endpoint => _endpoint;
  bool get hasMoreLog => nextCursor != null;

  /// Branches matching [query] (case-insensitive substring), the tracked
  /// branch first, then by name.
  List<KovaGitBranch> get visibleBranches {
    final needle = query.trim().toLowerCase();
    final tracked = status?.upstreamBranch;
    final list = [
      for (final branch in branches)
        if (needle.isEmpty || branch.name.toLowerCase().contains(needle))
          branch,
    ];
    list.sort((a, b) {
      if (a.name == tracked) return -1;
      if (b.name == tracked) return 1;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// The origin branch that matches the checkout: the tracked branch, else
  /// the local branch name when origin has it, else null.
  String? get defaultResetBranch {
    final names = {for (final b in branches) b.name};
    final tracked = status?.upstreamBranch;
    if (tracked != null && names.contains(tracked)) return tracked;
    final local = status?.branch;
    if (local != null && names.contains(local)) return local;
    return null;
  }

  /// The only branch a reset is checked against: the current branch
  /// ([defaultResetBranch]) while HEAD is on one, null when HEAD is detached
  /// or origin does not have it ([resetBlock] says which).
  String? get resetBranch {
    final current = status;
    if (current == null || current.detached) return null;
    return defaultResetBranch;
  }

  /// Why a commit of the history cannot be previewed as a reset, or null
  /// when it can (or nothing is loaded yet).
  KovaGitResetBlock? get resetBlock {
    final current = status;
    if (current == null) return null;
    if (current.detached) return KovaGitResetBlock.detached;
    if (defaultResetBranch == null) return KovaGitResetBlock.notFetched;
    return null;
  }

  /// Reset preview request for [commit] inside the current branch, or null
  /// while [resetBlock] is set. Never another branch.
  KovaGitPlanRequest? resetRequest(String commit) {
    final branch = resetBranch;
    if (branch == null) return null;
    return KovaGitPlanRequest.resetTo(branch: branch, commit: commit);
  }

  /// True when [branch] is what the comma runs now.
  bool isCurrent(KovaGitBranch branch) {
    final current = status;
    if (current == null) return false;
    return branch.commit == current.head &&
        (branch.name == current.upstreamBranch ||
            branch.name == current.branch);
  }

  void setQuery(String value) {
    if (value == query) return;
    query = value;
    _notify();
  }

  /// Reads status, branches and the first history page from [endpoint].
  Future<void> open(String endpoint) async {
    if (_endpoint != endpoint || _client == null) {
      _client?.close();
      _endpoint = endpoint;
      _client = _clientFactory(endpoint);
    }
    await refresh();
  }

  Future<void> refresh() async {
    final client = _client;
    final generation = ++_generation;
    if (client == null) {
      load = KovaGitLoad.failed;
      failure = const KovaGitException(
        KovaGitFailure.transport,
        KovaGitText.transport,
      );
      _notify();
      return;
    }
    load = KovaGitLoad.loading;
    failure = null;
    _notify();
    try {
      // The gateway runs one inspection at a time (`git_busy` otherwise),
      // so the three reads go one after another.
      final nextStatus = await client.status();
      final nextBranches = await client.branches();
      final page = await client.log(limit: pageSize);
      if (generation != _generation || _disposed) return;
      status = nextStatus;
      branches = List.unmodifiable(nextBranches);
      log = List.unmodifiable(page.entries);
      nextCursor = page.nextCursor;
      logFailure = null;
      load = KovaGitLoad.ready;
    } on KovaGitException catch (error) {
      if (generation != _generation || _disposed) return;
      failure = error;
      load = KovaGitLoad.failed;
    }
    _notify();
  }

  Future<void> loadMore() async {
    final client = _client;
    final cursor = nextCursor;
    if (client == null || cursor == null || loadingMore) return;
    final generation = _generation;
    loadingMore = true;
    logFailure = null;
    _notify();
    try {
      final page = await client.log(limit: pageSize, cursor: cursor);
      if (generation != _generation || _disposed) return;
      final known = {for (final e in log) e.commit};
      log = List.unmodifiable([
        ...log,
        for (final entry in page.entries)
          if (known.add(entry.commit)) entry,
      ]);
      nextCursor = page.nextCursor;
    } on KovaGitException catch (error) {
      if (generation != _generation || _disposed) return;
      logFailure = error;
    } finally {
      if (generation == _generation && !_disposed) {
        loadingMore = false;
        _notify();
      }
    }
  }

  /// Asks the comma what a switch or reset would do. Never applies it.
  /// A reset the comma refuses (400) is a commit outside that branch's
  /// history and says so; every other failure keeps its own line.
  Future<KovaGitPreview> preview(KovaGitPlanRequest request) async {
    final client = _client;
    if (client == null) {
      return const KovaGitPreview.failed(
        KovaGitException(KovaGitFailure.transport, KovaGitText.transport),
      );
    }
    try {
      return KovaGitPreview.plan(await client.plan(request));
    } on KovaGitException catch (error) {
      if (request.operation == KovaGitOperation.reset &&
          error.kind == KovaGitFailure.invalidRequest) {
        return KovaGitPreview.failed(
          KovaGitException(
            error.kind,
            KovaGitBranchText.notInBranch(request.branch),
            statusCode: error.statusCode,
            code: error.code,
          ),
        );
      }
      return KovaGitPreview.failed(error);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _client?.close();
    _client = null;
    super.dispose();
  }
}
