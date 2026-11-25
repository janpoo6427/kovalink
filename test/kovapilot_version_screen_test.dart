import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

import 'support/fake_kova_git_gateway.dart';

const _endpoint = 'http://192.168.0.40:8082';

class _Harness {
  _Harness() : gateway = FakeKovaGitGateway.sample() {
    controller = KovaGitController(
      clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
    );
  }

  final FakeKovaGitGateway gateway;
  late final KovaGitController controller;

  Widget app({String? endpoint = _endpoint}) => MaterialApp(
    theme: KovaLinkApp.theme(Brightness.dark),
    home: KovaPage(
      backTooltip: KovaRoutes.backToSettings,
      child: KovapilotVersionScreen(
        endpoint: endpoint,
        controller: controller,
        now: DateTime(2026, 11, 25, 16),
      ),
    ),
  );
}

Future<_Harness> _open(
  WidgetTester tester, {
  Size size = const Size(412, 915),
  void Function(FakeKovaGitGateway gateway)? setup,
  String? endpoint = _endpoint,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final h = _Harness();
  setup?.call(h.gateway);
  addTearDown(h.controller.dispose);
  await tester.pumpWidget(h.app(endpoint: endpoint));
  await tester.pumpAndSettle();
  return h;
}

/// The page list (a TextField has its own horizontal Scrollable).
final Finder _page = find
    .byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    )
    .first;

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(target, 250, scrollable: _page);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('status, notice, branches and history', (tester) async {
    final h = await _open(tester);
    final head = h.gateway.commitOf('master').sha;
    expect(find.text('kovapilot 버전'), findsOneWidget);
    expect(
      find.textContaining('지금은 미리보기만 할 수 있어요. 콤마에서 아직 바꾸기를 허용하지 않아요.'),
      findsOneWidget,
    );
    final status = find.byKey(const ValueKey('git-status-card'));
    expect(
      find.descendant(of: status, matching: find.text('master')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: status, matching: find.text(shortCommit(head))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: status, matching: find.text('origin/master')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: status, matching: find.text('없어요')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: status, matching: find.text('쉬고 있어요')),
      findsOneWidget,
    );
    expect(find.text('브랜치 4개'), findsOneWidget);
    expect(find.byKey(const ValueKey('git-branch-master')), findsOneWidget);
    // Tracked branch first.
    final tiles = tester.widgetList<ListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('git-branches-card')),
        matching: find.byType(ListTile),
      ),
    );
    expect(tiles.first.key, const ValueKey('git-branch-master'));
    await _show(tester, find.byKey(const ValueKey('git-log-more')));
    expect(find.byKey(ValueKey('git-commit-$head')), findsOneWidget);
    expect(h.gateway.applyCalls, 0);
  });

  testWidgets('shows branch and commit when worktree state is unknown', (
    tester,
  ) async {
    final h = await _open(
      tester,
      setup: (gateway) => gateway
        ..dirty = true
        ..dirtyKnown = false,
    );
    final status = find.byKey(const ValueKey('git-status-card'));
    expect(
      find.descendant(of: status, matching: find.text('master')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: status,
        matching: find.text(shortCommit(h.gateway.commitOf('master').sha)),
      ),
      findsOneWidget,
    );
    expect(find.text('확인 못 했어요'), findsOneWidget);
  });

  testWidgets('branch search and its empty state', (tester) async {
    await _open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('git-branch-search')),
      'shadow',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('git-branch-feature/longitudinal-shadow')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('git-branch-master')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('git-branch-search')),
      'nope',
    );
    await tester.pump();
    expect(find.text('‘nope’ 브랜치가 없어요.'), findsOneWidget);
    await tester.tap(find.byTooltip('지우기'));
    await tester.pump();
    expect(find.byKey(const ValueKey('git-branch-master')), findsOneWidget);
  });

  testWidgets('switch preview: files, restart, 적용 off with its reason', (
    tester,
  ) async {
    final h = await _open(tester);
    await tester.tap(
      find.byKey(const ValueKey('git-branch-feature/longitudinal-shadow')),
    );
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('git-preview-dialog'));
    expect(
      find.descendant(of: dialog, matching: find.text('브랜치 바꾸기 미리보기')),
      findsOneWidget,
    );
    final shadow = h.gateway.commitOf('feature/longitudinal-shadow');
    final files = h.gateway.changedFiles(h.gateway.head, shadow);
    expect(
      find.descendant(of: dialog, matching: find.text('$files개')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(shortCommit(shadow.sha))),
      findsOneWidget,
    );
    expect(find.text('적용하면 kovapilot을 다시 시작해야 해요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('git-plan-dirty')), findsNothing);
    final apply = tester.widget<FilledButton>(
      find.byKey(const ValueKey('git-apply')),
    );
    expect(apply.onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('git-apply-locked')),
        matching: find.text('콤마에서 아직 바꾸기를 허용하지 않아요.'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('git-apply')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(h.gateway.applyCalls, 0);
    expect(h.gateway.requests.where((r) => r.contains('apply')), isEmpty);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('switching to the branch in use changes nothing', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('git-branch-master')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-plan-files')), findsOneWidget);
    expect(find.text('이미 이 커밋이라 달라지는 게 없어요.'), findsOneWidget);
    expect(find.text('적용하면 kovapilot을 다시 시작해야 해요.'), findsNothing);
  });

  testWidgets('modified files: status and preview warn', (tester) async {
    await _open(tester, setup: (g) => g.dirty = true);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('git-dirty'))).data,
      '있어요',
    );
    expect(find.text('콤마에서 직접 고친 파일이 있어요. 바꾸기 전에 확인해야 해요.'), findsOneWidget);
    await _show(
      tester,
      find.byKey(const ValueKey('git-branch-release/stable')),
    );
    await tester.tap(find.byKey(const ValueKey('git-branch-release/stable')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-plan-dirty')), findsOneWidget);
  });

  testWidgets(
    'switch preview compares commits when local changes are unknown',
    (tester) async {
      final harness = await _open(
        tester,
        setup: (gateway) => gateway
          ..dirtyKnown = false
          ..dirty = true,
      );
      final branch = find.byKey(const ValueKey('git-branch-release/stable'));
      await _show(tester, branch);
      await tester.tap(branch);
      await tester.pumpAndSettle();
      expect(find.text('커밋 간 변경 파일'), findsOneWidget);
      expect(find.text('콤마에서 직접 수정한 파일이 있는지 확인하지 못했어요.'), findsOneWidget);
      expect(harness.gateway.applyCalls, 0);
    },
  );

  testWidgets('reset preview from history stays on the current branch', (
    tester,
  ) async {
    final h = await _open(tester);
    final older = h.gateway.headHistory()[4];
    final tile = find.byKey(ValueKey('git-commit-${older.sha}'));
    await _show(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('이 커밋으로 되돌리기 미리보기'), findsOneWidget);
    expect(h.gateway.posts.last, {
      'operation': 'reset',
      'branch': 'master',
      'commit': older.sha,
    });
    expect(find.text('master의 최신 커밋보다 앞선 커밋으로 돌아가요.'), findsOneWidget);
    // Nothing to pick: one fixed line names the branch.
    expect(find.byKey(const ValueKey('git-reset-branch')), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('git-reset-branch-fixed')),
        matching: find.text('지금 브랜치 ‘master’ 안에서 되돌려요.'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('git-switch-then-pick')), findsNothing);
    expect(h.gateway.posts.map((p) => p['branch']).toSet(), {'master'});
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('git-apply')))
          .onPressed,
      isNull,
    );
    expect(h.gateway.applyCalls, 0);
  });

  testWidgets('history and its note name the current branch', (tester) async {
    await _open(tester);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('git-branches-note'))).data,
      '브랜치를 누르면 바꿨을 때 무엇이 달라지는지 미리 볼 수 있어요. '
      '다른 브랜치의 커밋으로 가려면 먼저 그 브랜치로 바꾼 뒤, 그 브랜치의 커밋 기록에서 골라요.',
    );
    await _show(tester, find.text('‘master’ 커밋 기록'));
    expect(find.text('커밋 기록'), findsNothing);
    expect(find.byKey(const ValueKey('git-reset-blocked')), findsNothing);
    await _show(tester, find.byKey(const ValueKey('git-history-note')));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('git-history-note'))).data,
      '지금 브랜치 ‘master’의 커밋만 보여요. '
      '커밋을 누르면 그 커밋으로 되돌렸을 때를 미리 볼 수 있어요. 길게 누르면 커밋 번호를 복사해요.',
    );
  });

  testWidgets('switch preview to another branch: pick its commits after', (
    tester,
  ) async {
    final h = await _open(tester);
    await tester.tap(
      find.byKey(const ValueKey('git-branch-feature/longitudinal-shadow')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('git-switch-then-pick')),
        matching: find.text(
          '바꾼 뒤 ‘feature/longitudinal-shadow’의 커밋 기록에서 되돌릴 커밋을 고를 수 있어요.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('git-reset-branch-fixed')), findsNothing);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    // The branch in use: nothing new to pick after it.
    await tester.tap(find.byKey(const ValueKey('git-branch-master')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-plan-files')), findsOneWidget);
    expect(find.byKey(const ValueKey('git-switch-then-pick')), findsNothing);
    expect(h.gateway.applyCalls, 0);
  });

  testWidgets('detached HEAD: no reset preview, copy still works', (
    tester,
  ) async {
    final h = await _open(
      tester,
      setup: (g) => g
        ..head = g.headHistory()[3]
        ..branch = null
        ..upstream = null,
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final blocked = find.byKey(const ValueKey('git-reset-blocked'));
    await _show(tester, blocked);
    expect(
      find.descendant(
        of: blocked,
        matching: find.text(
          '지금 콤마는 브랜치 없이 커밋에 고정돼 있어서 여기서 되돌릴 수 없어요. 먼저 브랜치로 바꿔 주세요.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('커밋 기록'), findsOneWidget);
    final older = h.gateway.headHistory()[2];
    final tile = find.byKey(ValueKey('git-commit-${older.sha}'));
    await _show(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-preview-dialog')), findsNothing);
    expect(h.gateway.posts, isEmpty);
    await tester.longPress(tile);
    await tester.pump();
    expect(copied, older.sha);
    await _show(tester, find.byKey(const ValueKey('git-history-note')));
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('git-history-note'))).data,
      '지금 고정된 커밋까지의 기록이에요. 길게 누르면 커밋 번호를 복사해요.',
    );
  });

  testWidgets('detached HEAD: the button brings the branch list back', (
    tester,
  ) async {
    final h = await _open(
      tester,
      setup: (g) {
        g
          ..branch = null
          ..upstream = null;
        // A comma with many fetched branches: the list is far above.
        for (var i = 0; i < 24; i++) {
          g.origin['feature/extra-${i.toString().padLeft(2, '0')}'] = g.head;
        }
      },
    );
    final blocked = find.byKey(const ValueKey('git-reset-blocked'));
    await _show(tester, blocked);
    final title = find.text('브랜치 28개');
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(
      title.evaluate().isEmpty || tester.getRect(title).bottom < 0,
      isTrue,
      reason: 'the branch list starts off screen',
    );
    await tester.tap(find.byKey(const ValueKey('git-show-branches')));
    await tester.pumpAndSettle();
    expect(tester.getRect(title).top, inInclusiveRange(56, screen.height / 2));
    final shadow = find.byKey(
      const ValueKey('git-branch-feature/longitudinal-shadow'),
    );
    await _show(tester, shadow);
    await tester.tap(shadow);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-switch-then-pick')), findsOneWidget);
    expect(h.gateway.posts.single, {
      'operation': 'switch',
      'branch': 'feature/longitudinal-shadow',
    });
  });

  testWidgets('detached HEAD on a tablet: the left column scrolls', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(1194, 834),
      setup: (g) {
        g
          ..branch = null
          ..upstream = null;
        for (var i = 0; i < 24; i++) {
          g.origin['feature/extra-${i.toString().padLeft(2, '0')}'] = g.head;
        }
      },
    );
    final left = find.byKey(const ValueKey('git-left-column'));
    await tester.drag(left, const Offset(0, -1400));
    await tester.pumpAndSettle();
    final title = find.text('브랜치 28개');
    expect(
      title.evaluate().isEmpty || tester.getRect(title).bottom < 0,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('git-show-branches')));
    await tester.pumpAndSettle();
    expect(tester.getRect(title).top, inInclusiveRange(56, 834 / 2));
  });

  testWidgets('a branch origin does not have: no reset preview', (
    tester,
  ) async {
    final h = await _open(
      tester,
      setup: (g) => g
        ..branch = 'my-local-work'
        ..upstream = null,
    );
    final blocked = find.byKey(const ValueKey('git-reset-blocked'));
    await _show(tester, blocked);
    expect(
      find.descendant(
        of: blocked,
        matching: find.text(
          '지금 브랜치 ‘my-local-work’는 콤마가 받아 둔 브랜치 목록에 없어서 여기서 되돌릴 수 없어요. 먼저 브랜치로 바꿔 주세요.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('‘my-local-work’ 커밋 기록'), findsOneWidget);
    final tile = find.byKey(
      ValueKey('git-commit-${h.gateway.headHistory()[1].sha}'),
    );
    await _show(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-preview-dialog')), findsNothing);
    expect(h.gateway.posts, isEmpty);
  });

  testWidgets('a commit made only on the comma: refused in plain words', (
    tester,
  ) async {
    late String local;
    final h = await _open(
      tester,
      setup: (g) => local = g.commitOnComma('wip: 콤마에서만 만든 커밋').sha,
    );
    final tile = find.byKey(ValueKey('git-commit-$local'));
    await _show(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(h.gateway.posts.last, {
      'operation': 'reset',
      'branch': 'master',
      'commit': local,
    });
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('git-preview-failure')))
          .data,
      '이 커밋은 ‘master’ 브랜치 기록에 없어서 되돌릴 수 없어요.',
    );
    expect(find.text(KovaGitText.invalidRequest), findsNothing);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    // A switch the comma refuses keeps its own words.
    h.gateway.origin.remove('release/stable');
    final stable = find.byKey(const ValueKey('git-branch-release/stable'));
    // The branch list is above the history: scroll back up to it.
    await tester.scrollUntilVisible(stable, -250, scrollable: _page);
    await tester.pumpAndSettle();
    await tester.tap(stable);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('git-preview-failure')))
          .data,
      KovaGitText.invalidRequest,
    );
    expect(h.gateway.applyCalls, 0);
  });

  testWidgets('after the comma switches branch, 새로 읽기 follows it', (
    tester,
  ) async {
    final h = await _open(tester);
    h.gateway.checkout('feature/longitudinal-shadow');
    await tester.tap(find.byKey(const ValueKey('git-refresh')));
    await tester.pumpAndSettle();
    final shadow = h.gateway.commitOf('feature/longitudinal-shadow');
    await _show(tester, find.text('‘feature/longitudinal-shadow’ 커밋 기록'));
    final older = h.gateway.headHistory()[1];
    expect(older.subject, 'test(longitudinal): shadow planner replay');
    final tile = find.byKey(ValueKey('git-commit-${older.sha}'));
    await _show(tester, tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(h.gateway.posts.last, {
      'operation': 'reset',
      'branch': 'feature/longitudinal-shadow',
      'commit': older.sha,
    });
    expect(
      find.text('지금 브랜치 ‘feature/longitudinal-shadow’ 안에서 되돌려요.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('git-plan')),
        matching: find.text(shortCommit(shadow.sha)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('more history until the end', (tester) async {
    final h = await _open(tester);
    final more = find.byKey(const ValueKey('git-log-more'));
    await _show(tester, more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(h.controller.log, hasLength(30));
    expect(more, findsNothing);
    final first = h.gateway.headHistory().last;
    await _show(tester, find.byKey(ValueKey('git-commit-${first.sha}')));
    expect(
      find.text('chore: start kovapilot from upstream openpilot'),
      findsOneWidget,
    );
  });

  testWidgets('long press copies the full commit number', (tester) async {
    final h = await _open(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final head = h.gateway.commitOf('master').sha;
    final chip = find.descendant(
      of: find.byKey(const ValueKey('git-status-card')),
      matching: find.byType(KovaCommitChip),
    );
    await tester.longPress(chip);
    await tester.pump();
    expect(copied, head);
    expect(find.text('커밋 번호 ${shortCommit(head)}를 복사했어요.'), findsOneWidget);
  });

  testWidgets('loopback-only comma: found, but phones are not allowed yet', (
    tester,
  ) async {
    final h = await _open(tester, setup: (g) => g.mode = FakeGitMode.localOnly);
    expect(find.byKey(const ValueKey('git-failure-localOnly')), findsOneWidget);
    expect(find.text('콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.'), findsOneWidget);
    expect(find.text(KovaGitText.localOnlyDetail), findsOneWidget);
    expect(find.textContaining('콤마가 아니'), findsNothing);
    h.gateway.mode = FakeGitMode.normal;
    await tester.tap(find.text('다시 해 보기'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('git-status-card')), findsOneWidget);
  });

  testWidgets('no connection, busy, unreadable checkout, old kovapilot', (
    tester,
  ) async {
    for (final (mode, key, text) in [
      (FakeGitMode.down, 'git-failure-transport', KovaGitText.transport),
      (FakeGitMode.busy, 'git-failure-busy', KovaGitText.busy),
      (
        FakeGitMode.unavailable,
        'git-failure-unavailable',
        KovaGitText.unavailable,
      ),
      (
        FakeGitMode.oldGateway,
        'git-failure-unsupported',
        KovaGitText.unsupported,
      ),
      (FakeGitMode.timeout, 'git-failure-timeout', KovaGitText.timeout),
    ]) {
      await _open(tester, setup: (g) => g.mode = mode);
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '$mode');
      expect(find.text(text), findsOneWidget, reason: '$mode');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('loading, then no branches and no history', (tester) async {
    tester.view.physicalSize = const Size(824, 1830);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final h = _Harness();
    addTearDown(h.controller.dispose);
    h.gateway
      ..hold = Completer<void>()
      ..origin.clear();
    await tester.pumpWidget(h.app());
    await tester.pump();
    expect(find.byKey(const ValueKey('git-loading')), findsOneWidget);
    expect(find.text('콤마에서 kovapilot 버전을 읽고 있어요.'), findsOneWidget);
    h.gateway.hold!.complete();
    h.gateway.hold = null;
    await tester.pumpAndSettle();
    expect(find.text('콤마가 받아 둔 브랜치가 없어요.'), findsOneWidget);
    expect(find.byKey(const ValueKey('git-branch-search')), findsNothing);
  });

  testWidgets('without a comma address', (tester) async {
    await _open(tester, endpoint: null);
    expect(find.byKey(const ValueKey('git-no-endpoint')), findsOneWidget);
    expect(find.text('먼저 콤마에 연결해 주세요.'), findsOneWidget);
  });

  testWidgets('two columns on a tablet or a phone on its side', (tester) async {
    await _open(tester, size: const Size(1194, 834));
    expect(find.byKey(const ValueKey('git-left-column')), findsOneWidget);
    expect(find.byKey(const ValueKey('git-right-column')), findsOneWidget);
    final left = tester.getRect(find.byKey(const ValueKey('git-status-card')));
    final right = tester.getRect(
      find.byKey(const ValueKey('git-history-card')),
    );
    expect(right.left, greaterThan(left.right));
    await tester.pumpWidget(const SizedBox());
    await _open(tester, size: const Size(412, 915));
    expect(find.byKey(const ValueKey('git-left-column')), findsNothing);
  });

  test('updater words and commit times', () {
    expect(kovaUpdaterStateLabel(null), '알 수 없어요');
    expect(kovaUpdaterStateLabel('idle'), '쉬고 있어요');
    expect(kovaUpdaterStateLabel('checking...'), '새 버전을 확인하고 있어요');
    expect(kovaUpdaterStateLabel('downloading...'), '새 버전을 받고 있어요');
    expect(kovaUpdaterStateLabel('finalizing update...'), '새 버전을 준비하고 있어요');
    expect(kovaUpdaterStateLabel('custom'), 'custom');
    final now = DateTime(2026, 11, 25, 16);
    expect(
      kovaCommitTimeLabel(DateTime(2026, 11, 22, 20, 6), now: now),
      '11월 22일 20:06',
    );
    expect(
      kovaCommitTimeLabel(DateTime(2025, 3, 2, 9), now: now),
      '2025년 3월 2일',
    );
    expect(kovaCommitTimeLabel(null), '');
    expect(kovaApplyLockedReason(false), '콤마에서 아직 바꾸기를 허용하지 않아요.');
    expect(kovaApplyLockedReason(true), '이 앱에서는 아직 바꾸기를 할 수 없어요.');
  });
}
