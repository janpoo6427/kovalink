// State for the kovapilot version screen: current checkout, fetched origin
// branches, HEAD history pages and switch/reset previews. Read-only; the
// apply step is never sent.
import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

typedef KovaGitClientFactory = KovaGitClient? Function(String endpoint);

enum KovaGitLoad { idle, loading, ready, failed }

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

  /// Branch a reset is checked against by default: the tracked branch, else
  /// the local branch name when origin has it, else null (the user picks).
  String? get defaultResetBranch {
    final names = {for (final b in branches) b.name};
    final tracked = status?.upstreamBranch;
    if (tracked != null && names.contains(tracked)) return tracked;
    final local = status?.branch;
    if (local != null && names.contains(local)) return local;
    return null;
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
