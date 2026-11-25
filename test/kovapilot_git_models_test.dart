import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kovapilot_git/git_models.dart';

// Answers copied from a real kovapilot gateway (master-jh@7cc3b3280) running
// in the worker container against its own checkout and a fixture repository.
const _realStatus =
    '{"branch": null, "head": "7cc3b3280a8a0ddc61c030de4449e7761e91d1c5", '
    '"upstream": null, "dirty": false, "updaterState": null, '
    '"mutationEnabled": false}';
const _realLog =
    '{"entries": [{"commit": "7cc3b3280a8a0ddc61c030de4449e7761e91d1c5", '
    '"parents": ["d25686f7b57ae6c939f9829b6cbbb653b935a072"], '
    '"authorTime": "2026-11-25T15:11:31+09:00", '
    '"subject": "feat(gateway): serve telemetry camera and git maintenance previews"}, '
    '{"commit": "d25686f7b57ae6c939f9829b6cbbb653b935a072", '
    '"parents": ["4541b861421ce2a1a399e4cffaeda0e93dfdb6cc"], '
    '"authorTime": "2026-11-25T14:11:07+09:00", '
    '"subject": "feat(display): add onroad screen brightness modes via kova_params"}], '
    '"nextCursor": 2}';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _c = 'cccccccccccccccccccccccccccccccccccccccc';
const _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Map<String, Object?> _plan({Map<String, Object?> extra = const {}}) => {
  'operation': 'reset',
  'branch': 'master',
  'commit': _b,
  'branchHead': _a,
  'beforeHead': _a,
  'beforeBranch': 'master',
  'dirty': true,
  'requiresRestart': true,
  'mutationEnabled': false,
  'changedFileCount': 4,
  'planDigest': _digest,
  ...extra,
};

void main() {
  group('status', () {
    test('detached checkout from a real gateway', () {
      final status = KovaGitStatus.fromJson(jsonDecode(_realStatus));
      expect(status.head, '7cc3b3280a8a0ddc61c030de4449e7761e91d1c5');
      expect(status.detached, isTrue);
      expect(status.upstream, isNull);
      expect(status.upstreamBranch, isNull);
      expect(status.dirty, isFalse);
      expect(status.updaterState, isNull);
      expect(status.mutationEnabled, isFalse);
    });

    test('tracked branch and updater state', () {
      final status = KovaGitStatus.fromJson({
        'branch': 'master',
        'head': _a,
        'upstream': 'origin/master',
        'dirty': true,
        'updaterState': ' idle ',
        'mutationEnabled': false,
      });
      expect(status.branch, 'master');
      expect(status.upstreamBranch, 'master');
      expect(status.dirty, isTrue);
      expect(status.updaterState, 'idle');
    });

    test('non-origin upstream has no plan branch', () {
      final status = KovaGitStatus.fromJson({
        'branch': 'x',
        'head': _a,
        'upstream': 'fork/x',
        'dirty': false,
      });
      expect(status.upstreamBranch, isNull);
      expect(status.mutationEnabled, isFalse);
    });

    test('odd updater state is unknown, not a failure', () {
      final status = KovaGitStatus.fromJson({
        'branch': null,
        'head': _a,
        'upstream': null,
        'dirty': false,
        'updaterState': 3,
      });
      expect(status.updaterState, isNull);
    });

    test('short or missing head is refused', () {
      for (final head in ['7cc3b3280', null, _a.toUpperCase(), '${_a}0']) {
        expect(
          () => KovaGitStatus.fromJson({'head': head, 'dirty': false}),
          throwsA(isA<KovaGitFormatException>()),
          reason: '$head',
        );
      }
      expect(
        () => KovaGitStatus.fromJson({'head': _a}),
        throwsA(isA<KovaGitFormatException>()),
      );
      expect(
        () => KovaGitStatus.fromJson([_a]),
        throwsA(isA<KovaGitFormatException>()),
      );
    });
  });

  group('branches', () {
    test('origin refs', () {
      final list = parseKovaGitBranches({
        'branches': [
          {'name': 'master', 'commit': _a},
          {'name': 'feature/longitudinal-shadow', 'commit': _b},
        ],
      });
      expect(list.map((b) => b.name), [
        'master',
        'feature/longitudinal-shadow',
      ]);
      expect(list.first, const KovaGitBranch(name: 'master', commit: _a));
    });

    test('empty list is fine; bad entries are not', () {
      expect(parseKovaGitBranches({'branches': []}), isEmpty);
      expect(
        () => parseKovaGitBranches({
          'branches': [
            {'name': '', 'commit': _a},
          ],
        }),
        throwsA(isA<KovaGitFormatException>()),
      );
      expect(
        () => parseKovaGitBranches({
          'branches': [
            {'name': 'x', 'commit': 'abc'},
          ],
        }),
        throwsA(isA<KovaGitFormatException>()),
      );
      expect(
        () => parseKovaGitBranches({'branch': []}),
        throwsA(isA<KovaGitFormatException>()),
      );
    });
  });

  group('log', () {
    test('real gateway page', () {
      final page = KovaGitLogPage.fromJson(jsonDecode(_realLog));
      expect(page.entries, hasLength(2));
      expect(page.nextCursor, 2);
      final first = page.entries.first;
      expect(first.parents, ['d25686f7b57ae6c939f9829b6cbbb653b935a072']);
      expect(first.isMerge, isFalse);
      expect(first.authorTime, DateTime.utc(2026, 11, 25, 6, 11, 31));
      expect(first.subject, startsWith('feat(gateway)'));
    });

    test('last page, merge commit, unreadable time', () {
      final page = KovaGitLogPage.fromJson({
        'entries': [
          {
            'commit': _a,
            'parents': [_b, _c],
            'authorTime': 'yesterday',
            'subject': '',
          },
        ],
        'nextCursor': null,
      });
      expect(page.nextCursor, isNull);
      expect(page.entries.single.isMerge, isTrue);
      expect(page.entries.single.authorTime, isNull);
      expect(page.entries.single.subject, '');
    });

    test('malformed pages are refused', () {
      for (final body in <Object?>[
        {'entries': {}},
        {'entries': [], 'nextCursor': -1},
        {'entries': [], 'nextCursor': '2'},
        {
          'entries': [
            {
              'commit': _a,
              'parents': ['x'],
              'subject': 's',
            },
          ],
        },
        {
          'entries': [
            {'commit': _a, 'parents': [], 'subject': 3},
          ],
        },
      ]) {
        expect(
          () => KovaGitLogPage.fromJson(body),
          throwsA(isA<KovaGitFormatException>()),
          reason: '$body',
        );
      }
    });
  });

  group('plan', () {
    test('reset preview', () {
      final plan = KovaGitPlan.fromJson(_plan());
      expect(plan.operation, KovaGitOperation.reset);
      expect(plan.branch, 'master');
      expect(plan.commit, _b);
      expect(plan.beforeBranch, 'master');
      expect(plan.dirty, isTrue);
      expect(plan.requiresRestart, isTrue);
      expect(plan.mutationEnabled, isFalse);
      expect(plan.changedFileCount, 4);
      expect(plan.isNoOp, isFalse);
      expect(plan.behindBranchHead, isTrue);
    });

    test('switch to the branch already checked out is a no-op', () {
      final plan = KovaGitPlan.fromJson(
        _plan(
          extra: {
            'operation': 'switch',
            'commit': _a,
            'changedFileCount': 0,
            'beforeBranch': null,
          },
        ),
      );
      expect(plan.operation, KovaGitOperation.switchBranch);
      expect(plan.isNoOp, isTrue);
      expect(plan.beforeBranch, isNull);
    });

    test('malformed plans are refused', () {
      for (final extra in <Map<String, Object?>>[
        {'operation': 'apply'},
        {'changedFileCount': -1},
        {'changedFileCount': 1.5},
        {'planDigest': 'abc'},
        {'commit': 'b' * 39},
        {'requiresRestart': null},
      ]) {
        expect(
          () => KovaGitPlan.fromJson(_plan(extra: extra)),
          throwsA(isA<KovaGitFormatException>()),
          reason: '$extra',
        );
      }
    });

    test('request bodies match the gateway contract', () {
      expect(const KovaGitPlanRequest.switchTo('release/stable').toJson(), {
        'operation': 'switch',
        'branch': 'release/stable',
      });
      expect(
        const KovaGitPlanRequest.resetTo(branch: 'master', commit: _b).toJson(),
        {'operation': 'reset', 'branch': 'master', 'commit': _b},
      );
    });
  });

  test('short commit and full SHA check', () {
    expect(shortCommit(_a), 'aaaaaaaaa');
    expect(shortCommit('abc'), 'abc');
    expect(shortCommit(_a, length: 7), 'aaaaaaa');
    expect(isFullCommitSha(_a), isTrue);
    expect(isFullCommitSha('A' * 40), isFalse);
    expect(isFullCommitSha('a' * 39), isFalse);
    expect(isFullCommitSha(null), isFalse);
  });
}
