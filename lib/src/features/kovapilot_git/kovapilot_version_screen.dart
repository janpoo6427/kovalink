// 설정 → kovapilot → kovapilot 버전: what the comma runs (branch, commit,
// tracked branch, modified files, updater), the branches it has fetched and
// the commit history, plus switch/reset previews. 적용 in a preview hands
// that change to the comma's updater when the comma allows it (registered
// phone, car off, updater idle); otherwise it stays off with its reason.
// The comma downloads the change and moves to it on its next start; the
// screen follows the download and says when to restart. 콤마 다시 켜기 asks
// the comma to restart (car off) and follows it until it answers again.
//
// Branch first: the history is the current branch's, and a reset stays
// inside it. A commit of another branch is reached by switching to that
// branch first; on a detached HEAD the history only copies commit numbers.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/widgets/readable_width.dart';

const _muted = Color(0xFF8E9DA9);
const _warn = Color(0xFFFFC857);
const _accent = Color(0xFF58F2C2);

/// Two columns (branches and status | history) from this width up.
const double kovapilotVersionWideWidth = 840;

/// Plain words for the updater's Params text.
String kovaUpdaterStateLabel(String? state) => switch (state) {
  null => '알 수 없어요',
  'idle' => '쉬고 있어요',
  'checking...' => '새 버전을 확인하고 있어요',
  'downloading...' => '새 버전을 받고 있어요',
  'finalizing update...' => '새 버전을 준비하고 있어요',
  final other => other,
};

/// `11월 25일 15:11` in this year, `2025년 3월 2일` otherwise.
String kovaCommitTimeLabel(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final local = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  if (local.year != today.year) {
    return '${local.year}년 ${local.month}월 ${local.day}일';
  }
  return '${local.month}월 ${local.day}일 ${two(local.hour)}:${two(local.minute)}';
}

/// Why the comma does not allow 적용 now, from its `mutationBlock`.
String kovaMutationBlockText(String? block) => switch (block) {
  'authorization' => '등록한 휴대폰으로 연결해야 바꿀 수 있어요.',
  'offroadOrUpdaterBusy' => '시동을 끄고, 콤마가 다른 업데이트를 하지 않을 때 바꿀 수 있어요.',
  _ => KovaGitText.mutationDisabled,
};

/// Why 적용 is off for [plan] (or for the screen when [plan] is null), or
/// null when it can be pressed.
String? kovaApplyBlockReason(KovaGitStatus? status, KovaGitPlan? plan) {
  if (status?.applying ?? false) return '콤마가 이미 다른 바꾸기를 하고 있어요.';
  final enabled =
      (status?.mutationEnabled ?? false) && (plan?.mutationEnabled ?? true);
  if (!enabled) return kovaMutationBlockText(status?.mutationBlock);
  if (plan == null) return null;
  if (plan.isNoOp) return '이미 이 커밋이라 바꿀 게 없어요.';
  if (!plan.dirtyKnown) return '콤마에서 직접 수정한 파일이 있는지 확인하지 못해서 바꿀 수 없어요.';
  if (plan.dirty) return '콤마에 수정된 파일이 있어서 바꿀 수 없어요.';
  return null;
}

/// Why 콤마 다시 켜기 is off, or null when it can be pressed.
String? kovaRestartBlockReason(KovaGitStatus status) {
  if (status.restartEnabled) return null;
  if (status.maintenance?.phase == KovaGitMaintenancePhase.queued) {
    return '새 버전을 다 받은 뒤 다시 켤 수 있어요.';
  }
  if (status.mutationBlock == 'authorization') {
    return '등록한 휴대폰으로 연결해야 다시 켤 수 있어요.';
  }
  if ((status.updaterState ?? '').startsWith('finalizing')) {
    return '콤마가 새 버전을 준비하는 동안은 다시 켤 수 없어요.';
  }
  return '시동을 끄면 다시 켤 수 있어요.';
}

/// Why the updater stopped, from the maintenance `reason`.
String kovaApplyFailureText(String? reason) => switch (reason) {
  'checkoutChanged' => '받는 동안 콤마의 버전이 바뀌어서 멈췄어요.',
  'stagingMissing' => '받아 둔 새 버전이 없어져서 멈췄어요. 다시 적용해 주세요.',
  'workingTreeChanged' => '콤마에 수정된 파일이 생겨서 멈췄어요.',
  'stagingFailed' => '새 버전을 받지 못했어요. 콤마의 인터넷 연결을 확인하고 다시 해 주세요.',
  _ => '콤마에서 바꾸기가 멈췄어요. 다시 해 주세요.',
};

/// `‘master’ 브랜치의 1a2b3c4d5 커밋` (no commit: `…의 새 버전`). Both take 을/으로.
String kovaApplyTargetText(KovaGitMaintenance m) {
  final commit = m.commit;
  return commit == null
      ? '‘${m.branch}’ 브랜치의 새 버전'
      : '‘${m.branch}’ 브랜치의 ${shortCommit(commit)} 커밋';
}

/// Copies [sha] and says so in one line.
Future<void> _copyCommit(BuildContext context, String sha) async {
  await Clipboard.setData(ClipboardData(text: sha));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('커밋 번호 ${shortCommit(sha)}를 복사했어요.'),
        duration: const Duration(seconds: 2),
      ),
    );
}

class KovapilotVersionScreen extends StatefulWidget {
  const KovapilotVersionScreen({
    required this.endpoint,
    this.controller,
    this.now,
    this.sessionFor,
    super.key,
  });

  /// The comma's gateway origin (`http://<address>:8082`), or null when
  /// KovaLink has not found one yet.
  final String? endpoint;

  /// Injected by tests and captures; otherwise the screen owns one.
  final KovaGitController? controller;

  /// Clock for the commit times (captures).
  final DateTime? now;

  /// The open session to the comma at an address: a comma on Wi-Fi is read
  /// through it (same certificate check and token as settings).
  final GatewaySession? Function(String address)? sessionFor;

  static Route<void> route({
    required String? endpoint,
    KovaGitController? controller,
    GatewaySession? Function(String address)? sessionFor,
  }) => KovaPageRoute(
    name: KovaRoutes.kovapilotVersion,
    builder: (context) => KovaPage(
      title: "kovapilot 버전",
      subtitle: endpoint == null
          ? "설치된 브랜치와 커밋"
          : "${_KovapilotVersionScreenState._hostLabel(endpoint)} · 브랜치와 커밋",
      backTooltip: KovaRoutes.backToSettings,
      child: KovapilotVersionScreen(
        endpoint: endpoint,
        controller: controller,
        sessionFor: sessionFor,
      ),
    ),
  );

  @override
  State<KovapilotVersionScreen> createState() => _KovapilotVersionScreenState();
}

class _KovapilotVersionScreenState extends State<KovapilotVersionScreen> {
  late final KovaGitController _git =
      widget.controller ??
      KovaGitController(
        clientFactory: (endpoint) => KovaGitClient.tryCreate(
          endpoint,
          transport: widget.sessionFor?.call(endpoint)?.transport,
        ),
      );
  final _search = TextEditingController();
  final _branchesKey = GlobalKey(debugLabel: 'git-branches-section');

  @override
  void initState() {
    super.initState();
    _search.text = _git.query;
    final endpoint = widget.endpoint;
    if (endpoint != null &&
        (_git.load == KovaGitLoad.idle || _git.endpoint != endpoint)) {
      // After this frame: opening notifies listeners right away.
      Future.microtask(() {
        if (mounted) _git.open(endpoint);
      });
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) _git.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _preview(KovaGitPlanRequest request) => showDialog<void>(
    context: context,
    builder: (context) =>
        KovaGitPreviewDialog(controller: _git, initial: request),
  );

  void _previewSwitch(KovaGitBranch branch) =>
      _preview(KovaGitPlanRequest.switchTo(branch.name));

  void _previewReset(KovaGitLogEntry entry) {
    // Only inside the current branch; while blocked the history card says
    // why and does not call this.
    final request = _git.resetRequest(entry.commit);
    if (request != null) _preview(request);
  }

  /// Scrolls the branch list into view, just under the back button. A list
  /// far above may not be built (lists only build what is near the
  /// screen), so go to the top first.
  Future<void> _showBranches(BuildContext from) async {
    if (_branchesKey.currentContext == null) {
      final position = Scrollable.maybeOf(from)?.position;
      position?.jumpTo(position.minScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _revealBranches();
  }

  Future<void> _revealBranches() async {
    final target = _branchesKey.currentContext;
    if (target == null) return;
    final scrollable = Scrollable.maybeOf(target);
    final box = target.findRenderObject();
    final viewport = scrollable?.context.findRenderObject();
    if (scrollable == null || box is! RenderBox || viewport is! RenderBox) {
      return;
    }
    final position = scrollable.position;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    await position.animateTo(
      (position.pixels + top - 8).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _git,
    builder: (context, _) => LayoutBuilder(
      builder: (context, box) {
        final body = _body();
        if (body != null) {
          return ReadableListView(children: [body]);
        }
        final current = _git.status!;
        final canRestart =
            !_git.restartBusy && kovaRestartBlockReason(current) == null;
        final status = _StatusCard(
          status: current,
          onRefresh: _git.refresh,
          refreshing:
              _git.load == KovaGitLoad.loading ||
              _git.restartState == KovaGitRestart.restarting,
          onRestart: canRestart ? _restart : null,
          restarting: _git.restartBusy,
        );
        final branches = _BranchesCard(
          key: _branchesKey,
          controller: _git,
          search: _search,
          onPick: _previewSwitch,
        );
        final history = _HistoryCard(
          controller: _git,
          now: widget.now,
          onPick: _previewReset,
          onShowBranches: _showBranches,
        );
        final restartCard = _git.restartState == KovaGitRestart.idle
            ? null
            : _RestartCard(
                state: _git.restartState,
                staged:
                    current.maintenance?.phase ==
                    KovaGitMaintenancePhase.staged,
                onRefresh: _git.refresh,
              );
        final notice = current.applying || restartCard != null
            ? null
            : _ApplyNotice(status: current);
        final maintenance = current.maintenance;
        final progress = maintenance == null
            ? null
            : _MaintenanceCard(
                maintenance: maintenance,
                updaterState: current.updaterState,
                onRestart: canRestart ? _restart : null,
              );
        if (box.maxWidth < kovapilotVersionWideWidth) {
          return ReadableListView(
            children: [
              ?restartCard,
              ?notice,
              ?progress,
              status,
              branches,
              history,
            ],
          );
        }
        // Tablets and phones on their side: status and branches on the
        // left, history on the right, each scrolling on its own.
        final width = math.min(box.maxWidth - 40, 1160.0);
        final bottom = 32 + MediaQuery.paddingOf(context).bottom;
        return Center(
          child: SizedBox(
            width: width,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ListView(
                    key: const ValueKey('git-left-column'),
                    padding: EdgeInsets.fromLTRB(0, 8, 0, bottom),
                    children: [
                      ?restartCard,
                      ?notice,
                      ?progress,
                      status,
                      branches,
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: ListView(
                    key: const ValueKey('git-right-column'),
                    padding: EdgeInsets.fromLTRB(0, 8, 0, bottom),
                    children: [const SizedBox(height: 2), history],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  /// Asks first: the connection drops while the comma restarts.
  Future<void> _restart() async {
    final staged =
        _git.status?.maintenance?.phase == KovaGitMaintenancePhase.staged;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('git-restart-dialog'),
        title: const Text('콤마를 다시 켤까요?'),
        content: Text(
          staged
              ? '받아 둔 새 버전으로 바뀌어요. 다시 켜는 1~2분 동안 연결이 끊겨요.'
              : '다시 켜는 1~2분 동안 연결이 끊겨요.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('git-restart-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('다시 켜기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final failure = await _git.restartComma();
    if (!mounted || failure == null) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failure.message)));
  }

  /// Loading, failure or not-connected content; null once loaded.
  Widget? _body() {
    if (widget.endpoint == null) {
      return const _StateCard(
        key: ValueKey('git-no-endpoint'),
        icon: Icons.link_off_rounded,
        title: '먼저 콤마에 연결해 주세요.',
        detail: '같은 와이파이나 핫스팟에서 콤마를 찾으면 여기서 버전을 볼 수 있어요.',
      );
    }
    final failure = _git.failure;
    if (_git.load == KovaGitLoad.failed && failure != null) {
      return _FailureCard(failure: failure, onRetry: _git.refresh);
    }
    if (_git.status == null) {
      return const _StateCard(
        key: ValueKey('git-loading'),
        icon: null,
        title: '콤마에서 kovapilot 버전을 읽고 있어요.',
      );
    }
    return null;
  }

  static String _hostLabel(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.host.isEmpty) return endpoint;
    return uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    this.detail,
    this.action,
    this.tone,
    super.key,
  });

  /// Null shows a spinner.
  final IconData? icon;
  final String title;
  final String? detail;
  final Widget? action;
  final Color? tone;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: icon == null
                    ? const Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : Icon(icon, color: tone ?? _muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Text(
                detail!,
                style: const TextStyle(color: _muted, height: 1.45),
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.only(left: 38), child: action),
          ],
        ],
      ),
    ),
  );
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.failure, required this.onRetry});

  final KovaGitException failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (icon, detail) = switch (failure.kind) {
      KovaGitFailure.localOnly => (
        Icons.phonelink_lock_outlined,
        KovaGitText.localOnlyDetail,
      ),
      KovaGitFailure.transport => (Icons.wifi_off_rounded, null),
      KovaGitFailure.timeout => (Icons.hourglass_empty_rounded, null),
      KovaGitFailure.busy => (Icons.hourglass_top_rounded, null),
      KovaGitFailure.unsupported => (
        Icons.system_update_outlined,
        '콤마의 kovapilot을 새 버전으로 올리면 볼 수 있어요.',
      ),
      _ => (Icons.error_outline_rounded, null),
    };
    return _StateCard(
      key: ValueKey('git-failure-${failure.kind.name}'),
      icon: icon,
      tone: failure.kind == KovaGitFailure.localOnly ? _warn : null,
      title: failure.message,
      detail: detail,
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('다시 해 보기'),
      ),
    );
  }
}

/// One line saying whether a preview can be applied, and why not.
class _ApplyNotice extends StatelessWidget {
  const _ApplyNotice({required this.status});

  final KovaGitStatus status;

  @override
  Widget build(BuildContext context) {
    final reason = kovaApplyBlockReason(status, null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        key: const ValueKey('git-apply-notice'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(
              reason == null
                  ? Icons.system_update_alt_rounded
                  : Icons.visibility_outlined,
              size: 18,
              color: _accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                reason == null
                    ? '브랜치나 커밋을 골라 미리 본 뒤 적용할 수 있어요. 콤마가 새 버전을 받아 두고, 다시 켤 때 바뀌어요.'
                    : '지금은 미리보기만 할 수 있어요. $reason',
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A restart from this phone: sending, waiting, back, or not back.
class _RestartCard extends StatelessWidget {
  const _RestartCard({
    required this.state,
    required this.staged,
    required this.onRefresh,
  });

  final KovaGitRestart state;
  final bool staged;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final (
      IconData? icon,
      Color? tone,
      String title,
      String? detail,
    ) = switch (state) {
      KovaGitRestart.idle ||
      KovaGitRestart.sending => (null, null, '콤마에 다시 켜기를 보내고 있어요.', null),
      KovaGitRestart.restarting => (
        null,
        null,
        '콤마를 다시 켜고 있어요.',
        staged
            ? '받아 둔 새 버전으로 바뀌어요. 1~2분 뒤 다시 연결되면 이 화면을 새로 읽어요.'
            : '1~2분 뒤 다시 연결되면 이 화면을 새로 읽어요.',
      ),
      KovaGitRestart.back => (
        Icons.check_circle_outline_rounded,
        _accent,
        '콤마가 다시 켜졌어요.',
        null,
      ),
      KovaGitRestart.lost => (
        Icons.portable_wifi_off_rounded,
        _warn,
        '콤마가 아직 다시 연결되지 않았어요.',
        '콤마 화면이 켜졌는지 보고, 같은 와이파이나 핫스팟에 있으면 새로 읽어 주세요.',
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _StateCard(
        key: ValueKey('git-restart-${state.name}'),
        icon: icon,
        tone: tone,
        title: title,
        detail: detail,
        action: state == KovaGitRestart.lost
            ? OutlinedButton.icon(
                key: const ValueKey('git-restart-refresh'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('새로 읽기'),
              )
            : null,
      ),
    );
  }
}

/// How far the last 적용 got on the comma.
class _MaintenanceCard extends StatelessWidget {
  const _MaintenanceCard({
    required this.maintenance,
    this.updaterState,
    this.onRestart,
  });

  final KovaGitMaintenance maintenance;
  final String? updaterState;

  /// Restarts the comma now (staged only); null when it cannot.
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final target = kovaApplyTargetText(maintenance);
    final (
      IconData? icon,
      Color? tone,
      String title,
      String detail,
    ) = switch (maintenance.phase) {
      KovaGitMaintenancePhase.queued => (
        null,
        null,
        '$target을 받고 있어요.',
        '이 화면을 닫아도 콤마는 계속 받아요. 다 받으면 콤마를 다시 켤 때 바뀌어요.',
      ),
      KovaGitMaintenancePhase.staged => (
        Icons.restart_alt_rounded,
        _accent,
        '$target을 받아 뒀어요.',
        onRestart != null
            ? '콤마를 다시 켜면 바뀌어요. 여기서 바로 다시 켤 수 있어요.'
            : '콤마를 다시 켜면 바뀌어요. 콤마 화면의 업데이트 알림에서 바로 다시 시작할 수도 있어요.',
      ),
      KovaGitMaintenancePhase.installed => (
        Icons.check_circle_outline_rounded,
        _accent,
        '$target으로 바뀌었어요.',
        '마지막으로 적용한 버전이에요.',
      ),
      KovaGitMaintenancePhase.failed => (
        Icons.error_outline_rounded,
        _warn,
        '$target으로 바꾸지 못했어요.',
        kovaApplyFailureText(maintenance.reason),
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: _StateCard(
        key: ValueKey('git-maintenance-${maintenance.phase.name}'),
        icon: icon,
        tone: tone,
        title: title,
        detail: detail,
        action:
            maintenance.phase == KovaGitMaintenancePhase.staged &&
                onRestart != null
            ? FilledButton.icon(
                key: const ValueKey('git-restart-staged'),
                onPressed: onRestart,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('지금 다시 켜기'),
              )
            : null,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8, top: 14),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: _muted, fontWeight: FontWeight.w700),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Short SHA in a fixed-width face; long press copies the full SHA.
class KovaCommitChip extends StatelessWidget {
  const KovaCommitChip(this.sha, {this.emphasis = false, super.key});

  final String sha;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '길게 눌러 커밋 번호 복사',
    triggerMode: TooltipTriggerMode.manual,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _copyCommit(context, sha),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: emphasis ? 0.12 : 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          shortCommit(sha),
          style: TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: const ['RobotoMono', 'Menlo', 'Roboto'],
            fontSize: 12.5,
            letterSpacing: 0.3,
            fontWeight: emphasis ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.note});

  final String label;
  final Widget value;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(
            label,
            style: const TextStyle(color: _muted, height: 1.5),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              value,
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    note!,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.onRefresh,
    required this.refreshing,
    this.onRestart,
    this.restarting = false,
  });

  final KovaGitStatus status;
  final VoidCallback onRefresh;
  final bool refreshing;

  /// Restarts the comma; null while it cannot.
  final VoidCallback? onRestart;
  final bool restarting;

  @override
  Widget build(BuildContext context) {
    final branch = status.branch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          '지금 콤마',
          trailing: SizedBox(
            height: 28,
            child: refreshing
                ? const Padding(
                    padding: EdgeInsets.all(5),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: const ValueKey('git-refresh'),
                    tooltip: '새로 읽기',
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
          ),
        ),
        Card(
          key: const ValueKey('git-status-card'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              children: [
                _Fact(
                  label: '브랜치',
                  value: Text(
                    branch ?? '브랜치 없이 커밋에 고정돼 있어요',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: branch == null ? _muted : null,
                      height: 1.5,
                    ),
                  ),
                ),
                _Fact(
                  label: '커밋',
                  value: Align(
                    alignment: Alignment.centerLeft,
                    child: KovaCommitChip(status.head, emphasis: true),
                  ),
                ),
                _Fact(
                  label: '따라가는 곳',
                  value: Text(
                    status.upstream ?? '없어요',
                    style: TextStyle(
                      color: status.upstream == null ? _muted : null,
                      height: 1.5,
                    ),
                  ),
                ),
                _Fact(
                  label: '수정된 파일',
                  value: Text(
                    !status.dirtyKnown && status.applying
                        ? '바꾸는 동안은 확인하지 않아요'
                        : !status.dirtyKnown
                        ? '확인 못 했어요'
                        : status.dirty
                        ? '있어요'
                        : '없어요',
                    key: const ValueKey('git-dirty'),
                    style: TextStyle(
                      color: status.dirty && !status.applying ? _warn : null,
                      fontWeight: status.dirty && !status.applying
                          ? FontWeight.w700
                          : null,
                      height: 1.5,
                    ),
                  ),
                  note: status.dirtyKnown && status.dirty
                      ? '콤마에서 직접 고친 파일이 있어요. 바꾸기 전에 확인해야 해요.'
                      : null,
                ),
                _Fact(
                  label: '업데이트',
                  value: Text(
                    kovaUpdaterStateLabel(status.updaterState),
                    style: const TextStyle(height: 1.5),
                  ),
                ),
                if (status.restartSupported) _restartRow(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

extension on _StatusCard {
  Widget _restartRow() {
    final reason = restarting ? null : kovaRestartBlockReason(status);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('git-restart'),
            onPressed: onRestart,
            icon: restarting
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restart_alt_rounded, size: 18),
            label: Text(restarting ? '콤마를 다시 켜고 있어요' : '콤마 다시 켜기'),
          ),
          if (reason != null) ...[
            const SizedBox(height: 6),
            Text(
              reason,
              key: const ValueKey('git-restart-reason'),
              style: const TextStyle(color: _muted, fontSize: 13, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _BranchesCard extends StatelessWidget {
  const _BranchesCard({
    required this.controller,
    required this.search,
    required this.onPick,
    super.key,
  });

  final KovaGitController controller;
  final TextEditingController search;
  final void Function(KovaGitBranch branch) onPick;

  @override
  Widget build(BuildContext context) {
    final all = controller.branches;
    final visible = controller.visibleBranches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('브랜치 ${all.length}개'),
        Card(
          key: const ValueKey('git-branches-card'),
          child: Column(
            children: [
              if (all.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    key: const ValueKey('git-branch-search'),
                    controller: search,
                    onChanged: controller.setQuery,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: '브랜치 이름으로 찾기',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      suffixIcon: controller.query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '지우기',
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                search.clear();
                                controller.setQuery('');
                              },
                            ),
                    ),
                  ),
                ),
              if (all.isEmpty)
                const _EmptyLine('콤마가 받아 둔 브랜치가 없어요.')
              else if (visible.isEmpty)
                _EmptyLine('‘${controller.query.trim()}’ 브랜치가 없어요.')
              else
                for (final (index, branch) in visible.indexed) ...[
                  if (index > 0) const Divider(height: 1, indent: 52),
                  ListTile(
                    key: ValueKey('git-branch-${branch.name}'),
                    leading: Icon(
                      Icons.call_split_rounded,
                      color: controller.isCurrent(branch) ? _accent : _muted,
                    ),
                    title: Text(
                      branch.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          KovaCommitChip(branch.commit),
                          if (controller.isCurrent(branch)) ...[
                            const SizedBox(width: 8),
                            const _Tag('지금 쓰는 중'),
                          ],
                        ],
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => onPick(branch),
                    onLongPress: () => _copyCommit(context, branch.commit),
                  ),
                ],
              const SizedBox(height: 4),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            '브랜치를 누르면 바꿨을 때 무엇이 달라지는지 미리 볼 수 있어요. '
            '${KovaGitBranchText.otherBranchCommits}',
            key: ValueKey('git-branches-note'),
            style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.controller,
    required this.onPick,
    required this.onShowBranches,
    this.now,
  });

  final KovaGitController controller;
  final void Function(KovaGitLogEntry entry) onPick;
  final void Function(BuildContext from) onShowBranches;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final log = controller.log;
    final head = controller.status?.head;
    final branch = controller.status?.branch;
    final failure = controller.logFailure;
    final block = controller.resetBlock;
    final note = [
      if (block == KovaGitResetBlock.detached)
        KovaGitBranchText.historyDetached
      else if (branch != null)
        KovaGitBranchText.historyOnly(branch),
      if (block == null) '커밋을 누르면 그 커밋으로 되돌렸을 때를 미리 볼 수 있어요.',
      '길게 누르면 커밋 번호를 복사해요.',
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(KovaGitBranchText.historyTitle(branch)),
        if (block != null)
          _ResetBlockedNotice(
            reason: switch (block) {
              KovaGitResetBlock.detached => KovaGitBranchText.detached,
              KovaGitResetBlock.notFetched => KovaGitBranchText.notFetched(
                branch ?? '',
              ),
            },
            onShowBranches: onShowBranches,
          ),
        Card(
          key: const ValueKey('git-history-card'),
          child: Column(
            children: [
              if (log.isEmpty) const _EmptyLine('커밋 기록이 없어요.'),
              for (final (index, entry) in log.indexed) ...[
                if (index > 0) const Divider(height: 1, indent: 16),
                ListTile(
                  key: ValueKey('git-commit-${entry.commit}'),
                  title: Text(
                    entry.subject.isEmpty ? '설명 없는 커밋' : entry.subject,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      color: entry.subject.isEmpty ? _muted : null,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        KovaCommitChip(entry.commit),
                        if (entry.authorTime != null)
                          Text(
                            kovaCommitTimeLabel(entry.authorTime, now: now),
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        if (entry.isMerge) const _Tag('합친 커밋', muted: true),
                        if (entry.commit == head) const _Tag('지금 쓰는 중'),
                      ],
                    ),
                  ),
                  onTap: block == null ? () => onPick(entry) : null,
                  onLongPress: () => _copyCommit(context, entry.commit),
                ),
              ],
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    failure.message,
                    style: const TextStyle(color: _warn, fontSize: 12.5),
                  ),
                ),
              if (controller.hasMoreLog || failure != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const ValueKey('git-log-more'),
                      onPressed: controller.loadingMore
                          ? null
                          : controller.loadMore,
                      child: controller.loadingMore
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(failure != null ? '다시 해 보기' : '더 보기'),
                    ),
                  ),
                )
              else
                const SizedBox(height: 4),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            note,
            key: const ValueKey('git-history-note'),
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// Above the history while a reset cannot be previewed: why, what to do and
/// a way to the branch list.
class _ResetBlockedNotice extends StatelessWidget {
  const _ResetBlockedNotice({
    required this.reason,
    required this.onShowBranches,
  });

  final String reason;
  final void Function(BuildContext from) onShowBranches;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('git-reset-blocked'),
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
    decoration: BoxDecoration(
      color: _warn.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _warn.withValues(alpha: 0.35)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.info_outline_rounded, size: 18, color: _warn),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$reason ${KovaGitBranchText.switchFirst}',
                style: const TextStyle(fontSize: 13, height: 1.45),
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('git-show-branches'),
            onPressed: () => onShowBranches(context),
            icon: const Icon(Icons.call_split_rounded, size: 18),
            label: const Text(KovaGitBranchText.showBranches),
          ),
        ),
      ],
    ),
  );
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
    child: Row(
      children: [
        const Icon(Icons.inbox_outlined, size: 18, color: _muted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(color: _muted)),
        ),
      ],
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.muted = false});

  final String text;
  final bool muted;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: (muted ? _muted : _accent).withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: muted ? _muted : _accent,
      ),
    ),
  );
}

/// What a switch or reset would do, asked from the comma. 적용 hands it to
/// the comma's updater when nothing blocks it; otherwise it is off and the
/// reason is shown.
class KovaGitPreviewDialog extends StatefulWidget {
  const KovaGitPreviewDialog({
    required this.controller,
    required this.initial,
    super.key,
  });

  final KovaGitController controller;
  final KovaGitPlanRequest initial;

  @override
  State<KovaGitPreviewDialog> createState() => _KovaGitPreviewDialogState();
}

class _KovaGitPreviewDialogState extends State<KovaGitPreviewDialog> {
  KovaGitPreview? _preview;
  int _asked = 0;
  bool _sending = false;
  KovaGitException? _applyFailure;

  /// Fixed: a reset stays inside the current branch, so there is nothing to
  /// pick here.
  KovaGitPlanRequest get _request => widget.initial;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    final ticket = ++_asked;
    setState(() {
      _preview = null;
      _applyFailure = null;
    });
    final preview = await widget.controller.preview(_request);
    if (!mounted || ticket != _asked) return;
    setState(() => _preview = preview);
  }

  bool get _isReset => _request.operation == KovaGitOperation.reset;

  Future<void> _apply(KovaGitPlan plan) async {
    setState(() {
      _sending = true;
      _applyFailure = null;
    });
    final failure = await widget.controller.apply(_request, plan);
    if (!mounted) return;
    if (failure == null) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('콤마가 새 버전을 받기 시작했어요.'),
            duration: Duration(seconds: 3),
          ),
        );
      return;
    }
    setState(() {
      _sending = false;
      _applyFailure = failure;
    });
  }

  /// A switch to a branch other than the current one: after it, that
  /// branch's history is where its commits are picked.
  bool get _isOtherBranch =>
      !_isReset && _request.branch != widget.controller.resetBranch;

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final plan = preview?.plan;
    final status = widget.controller.status;
    // Before the preview answers only the comma-wide reason can be known.
    final blocked = kovaApplyBlockReason(status, plan);
    final applyFailure = _applyFailure;
    return AlertDialog(
      key: const ValueKey('git-preview-dialog'),
      title: Text(_isReset ? '이 커밋으로 되돌리기 미리보기' : '브랜치 바꾸기 미리보기'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isReset) ...[
              _DialogNote(
                key: const ValueKey('git-reset-branch-fixed'),
                icon: Icons.call_split_rounded,
                text: KovaGitBranchText.resetInside(_request.branch),
              ),
              const SizedBox(height: 6),
            ],
            if (preview == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    SizedBox(width: 12),
                    Expanded(child: Text('콤마에 물어보고 있어요.')),
                  ],
                ),
              )
            else if (preview.failure case final failure?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded, color: _warn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        failure.message,
                        key: const ValueKey('git-preview-failure'),
                        style: const TextStyle(height: 1.45),
                      ),
                    ),
                  ],
                ),
              )
            else if (plan != null)
              _PlanFacts(plan: plan),
            if (_isOtherBranch) ...[
              const SizedBox(height: 10),
              _DialogNote(
                key: const ValueKey('git-switch-then-pick'),
                icon: Icons.history_rounded,
                text: KovaGitBranchText.pickAfterSwitch(_request.branch),
              ),
            ],
            if (applyFailure != null) ...[
              const SizedBox(height: 12),
              Row(
                key: const ValueKey('git-apply-failure'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline_rounded, color: _warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      applyFailure.message,
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            if (blocked != null)
              Row(
                key: const ValueKey('git-apply-locked'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: _muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      blocked,
                      style: const TextStyle(color: _muted, fontSize: 12.5),
                    ),
                  ),
                ],
              )
            else if (plan != null)
              const _DialogNote(
                key: ValueKey('git-apply-ready'),
                icon: Icons.system_update_alt_rounded,
                text: '적용하면 콤마가 새 버전을 받아 두고, 콤마를 다시 켤 때 바뀌어요.',
              ),
          ],
        ),
      ),
      actions: [
        if (preview?.failure != null || applyFailure != null)
          TextButton(
            onPressed: _sending ? null : _ask,
            child: const Text('다시 물어보기'),
          ),
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
        FilledButton(
          key: const ValueKey('git-apply'),
          onPressed: plan == null || blocked != null || _sending
              ? null
              : () => _apply(plan),
          child: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('적용'),
        ),
      ],
    );
  }
}

/// One quiet line with an icon at the top or bottom of a preview.
class _DialogNote extends StatelessWidget {
  const _DialogNote({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 17, color: _accent),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.4)),
      ),
    ],
  );
}

class _PlanFacts extends StatelessWidget {
  const _PlanFacts({required this.plan});

  final KovaGitPlan plan;

  @override
  Widget build(BuildContext context) {
    Widget where(String? branch, String commit) => Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          branch ?? '브랜치 없음',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: branch == null ? _muted : null,
          ),
        ),
        KovaCommitChip(commit),
      ],
    );

    return Column(
      key: const ValueKey('git-plan'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Fact(label: '지금', value: where(plan.beforeBranch, plan.beforeHead)),
        _Fact(
          label: '바꾼 뒤',
          value: where(plan.branch, plan.commit),
          note:
              plan.operation == KovaGitOperation.reset && plan.behindBranchHead
              ? '${plan.branch}의 최신 커밋보다 앞선 커밋으로 돌아가요.'
              : null,
        ),
        _Fact(
          label: plan.dirtyKnown ? '바뀌는 파일' : '커밋 간 변경 파일',
          value: Text(
            plan.isNoOp ? '없어요' : '${plan.changedFileCount}개',
            key: const ValueKey('git-plan-files'),
            style: const TextStyle(fontWeight: FontWeight.w700, height: 1.5),
          ),
          note: plan.isNoOp ? '이미 이 커밋이라 달라지는 게 없어요.' : null,
        ),
        if (plan.requiresRestart && !plan.isNoOp)
          const _Fact(
            label: '다시 시작',
            value: Text(
              '적용하면 kovapilot을 다시 시작해야 해요.',
              style: TextStyle(height: 1.5),
            ),
          ),
        if (!plan.dirtyKnown || plan.dirty)
          Container(
            key: const ValueKey('git-plan-dirty'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _warn.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: _warn, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    plan.dirtyKnown
                        ? '콤마에 수정된 파일이 있어요. 바꾸면 그 수정이 사라질 수 있으니 먼저 확인해 주세요.'
                        : '콤마에서 직접 수정한 파일이 있는지 확인하지 못했어요.',
                    style: const TextStyle(height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 설정 → kovapilot tab: the way into [KovapilotVersionScreen].
class KovapilotVersionEntry extends StatelessWidget {
  const KovapilotVersionEntry({
    required this.endpoint,
    this.sessionFor,
    super.key,
  });

  /// The comma's gateway origin the screen will read from.
  final String? endpoint;

  /// See [KovapilotVersionScreen.sessionFor].
  final GatewaySession? Function(String address)? sessionFor;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const ValueKey('kovapilot-version-entry'),
      leading: const Icon(Icons.commit_rounded),
      title: const Text('kovapilot 버전 및 Git'),
      subtitle: const Text('현재 브랜치, 커밋 기록, 변경 미리보기'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => KovaRoutes.open(
        context,
        KovapilotVersionScreen.route(
          endpoint: endpoint,
          sessionFor: sessionFor,
        ),
      ),
    ),
  );
}
