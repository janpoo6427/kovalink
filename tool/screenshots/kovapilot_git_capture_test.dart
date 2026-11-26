// Review captures of 설정 → kovapilot → kovapilot 버전 (not part of
// `flutter test`'s test/ directory).
//
//   KOVA_SHOT_DIR=out flutter test tool/screenshots/kovapilot_git_capture_test.dart
//
// Writes one PNG per state and two contact sheets (JPG) to $KOVA_SHOT_DIR:
// sheet_git_screens.jpg (phone portrait, phone landscape, tablets) and
// sheet_git_previews.jpg (switch preview, reset preview with modified files,
// the loopback-only refusal) and sheet_git_branch_first.jpg (the branch
// list's note, switch and reset previews, a detached HEAD and a commit made
// only on the comma). Data comes from the in-memory gateway in
// test/support/fake_kova_git_gateway.dart, which follows the kovapilot
// gateway contract; the real gateway is covered by
// test/kovapilot_git_e2e_test.dart.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_app.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/kovapilot_git/git_client.dart';
import 'package:kovalink/src/kovapilot_git/git_controller.dart';

import '../../test/support/device_profiles.dart';
import '../../test/support/fake_kova_git_gateway.dart';
import 'shot_support.dart';

const _endpoint = 'http://192.168.0.40:8082';

/// The page list (a TextField has its own horizontal Scrollable).
final Finder _page = find
    .byWidgetPredicate(
      (w) =>
          w is Scrollable &&
          axisDirectionToAxis(w.axisDirection) == Axis.vertical,
    )
    .first;

final _phone = portraitDevices.firstWhere((d) => d.id == 'phone_412x915');
final _phoneLandscape = landscapeDevices.firstWhere(
  (d) => d.id == 'phone_915x412',
);
final _tabletLandscape = landscapeDevices.firstWhere(
  (d) => d.id == 'tablet_1194x834',
);
final _tabletPortrait = portraitDevices.firstWhere(
  (d) => d.id == 'tablet_834x1194',
);

class _Shot {
  _Shot(this.name, this.title, this.subtitle, this.device);
  final String name;
  final String title;
  final String subtitle;
  final DeviceProfile device;
  String get path => '$shotDirectory/$name.png';
}

Future<void> _capture(
  WidgetTester tester,
  _Shot shot, {
  void Function(FakeKovaGitGateway gateway)? setup,
  Future<void> Function(WidgetTester tester, FakeKovaGitGateway gateway)? act,
}) async {
  shot.device.apply(tester);
  final gateway = FakeKovaGitGateway.sample();
  setup?.call(gateway);
  final controller = KovaGitController(
    clientFactory: (e) => KovaGitClient.tryCreate(e, transport: gateway),
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: KovaLinkApp.theme(Brightness.dark),
        home: KovaPage(
          title: "kovapilot 버전",
          backTooltip: KovaRoutes.backToSettings,
          child: KovapilotVersionScreen(
            endpoint: _endpoint,
            controller: controller,
            now: DateTime(2026, 11, 25, 16),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await act?.call(tester, gateway);
  await tester.pumpAndSettle();
  expect(gateway.applyCalls, 0);
  await saveBoundary(tester, key, shot.name, pixelRatio: shot.device.dpr);
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
  tester.view.reset();
}

Future<ui.Image> _load(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  return (await codec.getNextFrame()).image;
}

void _label(
  Canvas canvas,
  String text,
  Offset at,
  double size,
  Color color,
  double maxWidth, {
  FontWeight weight = FontWeight.w600,
}) {
  (TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Roboto',
        fontSize: size,
        color: color,
        fontWeight: weight,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth)).paint(canvas, at);
}

/// Captures scaled to [cellHeight] in rows up to [maxWidth] wide, labels on
/// top of each, as a JPG.
Future<void> _sheet(
  String name,
  String title,
  List<_Shot> shots, {
  double cellHeight = 1000,
  double maxWidth = 3400,
}) async {
  const gap = 28.0;
  const header = 120.0;
  const labelHeight = 84.0;
  final images = [for (final s in shots) await _load(s.path)];
  final widths = [for (final i in images) i.width * cellHeight / i.height];
  final rows = <List<int>>[[]];
  var run = gap;
  for (var i = 0; i < shots.length; i++) {
    if (rows.last.isNotEmpty && run + widths[i] + gap > maxWidth) {
      rows.add([]);
      run = gap;
    }
    rows.last.add(i);
    run += widths[i] + gap;
  }
  final width = rows
      .map((r) => r.fold(gap, (a, i) => a + widths[i] + gap))
      .reduce(math.max);
  final height = header + rows.length * (labelHeight + cellHeight + gap);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF1B1F24),
  );
  _label(
    canvas,
    title,
    const Offset(gap, 30),
    46,
    Colors.white,
    width - 2 * gap,
    weight: FontWeight.w800,
  );
  var y = header;
  for (final row in rows) {
    var x = gap;
    for (final i in row) {
      final shot = shots[i];
      _label(
        canvas,
        shot.title,
        Offset(x, y),
        30,
        Colors.white,
        widths[i],
        weight: FontWeight.w700,
      );
      _label(
        canvas,
        shot.subtitle,
        Offset(x, y + 40),
        23,
        const Color(0xFF9FB0BF),
        widths[i],
      );
      final dst = Rect.fromLTWH(x, y + labelHeight, widths[i], cellHeight);
      canvas.drawImageRect(
        images[i],
        Offset.zero &
            Size(images[i].width.toDouble(), images[i].height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.high,
      );
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF3A444F),
      );
      x += widths[i] + gap;
    }
    y += labelHeight + cellHeight + gap;
  }
  final image = await recorder.endRecording().toImage(
    width.round(),
    height.round(),
  );
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: raw!.buffer,
    numChannels: 4,
  );
  var quality = 88;
  var bytes = img.encodeJpg(out, quality: quality);
  while (bytes.length > 7.5 * 1024 * 1024 && quality > 50) {
    quality -= 8;
    bytes = img.encodeJpg(out, quality: quality);
  }
  File('$shotDirectory/$name.jpg')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

String _size(DeviceProfile d) =>
    '${d.label} · ${d.width.round()}×${d.height.round()}';

void main() {
  testWidgets('kovapilot version captures', (tester) async {
    await tester.runAsync(() async {
      await loadReviewFonts();
      // Commit numbers use the platform monospace face (Android
      // `monospace`, iOS Menlo); the test host has neither by that name.
      const mono = '/usr/share/fonts/dejavu-sans-mono-fonts';
      final loader = FontLoader('monospace');
      for (final file in ['DejaVuSansMono.ttf', 'DejaVuSansMono-Bold.ttf']) {
        final f = File('$mono/$file');
        if (f.existsSync()) {
          loader.addFont(
            Future.value(ByteData.sublistView(f.readAsBytesSync())),
          );
        }
      }
      await loader.load();
    });

    final phone = _Shot('git_phone_portrait', '폰 세로', _size(_phone), _phone);
    await _capture(tester, phone);

    final phoneHistory = _Shot(
      'git_phone_portrait_history',
      '폰 세로 · 커밋 기록',
      '20개씩, 맨 아래 더 보기',
      _phone,
    );
    await _capture(
      tester,
      phoneHistory,
      act: (tester, _) async {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('git-log-more')),
          400,
          scrollable: _page,
        );
        await tester.drag(_page, const Offset(0, -200));
      },
    );

    final phoneSide = _Shot(
      'git_phone_landscape',
      '폰 가로',
      _size(_phoneLandscape),
      _phoneLandscape,
    );
    await _capture(tester, phoneSide);

    final tablet = _Shot(
      'git_tablet_landscape',
      '태블릿 가로',
      _size(_tabletLandscape),
      _tabletLandscape,
    );
    await _capture(tester, tablet);

    final tabletTall = _Shot(
      'git_tablet_portrait',
      '태블릿 세로',
      _size(_tabletPortrait),
      _tabletPortrait,
    );
    await _capture(tester, tabletTall);

    final search = _Shot(
      'git_phone_branch_search',
      '브랜치 찾기',
      '“shadow”로 찾은 결과',
      _phone,
    );
    await _capture(
      tester,
      search,
      act: (tester, _) async {
        await tester.enterText(
          find.byKey(const ValueKey('git-branch-search')),
          'shadow',
        );
        await tester.pump();
        await tester.drag(_page, const Offset(0, -330));
      },
    );

    final switchPreview = _Shot(
      'git_switch_preview',
      '브랜치 바꾸기 미리보기',
      'feature/longitudinal-shadow · 적용은 꺼짐',
      _phone,
    );
    await _capture(
      tester,
      switchPreview,
      act: (tester, _) async {
        final tile = find.byKey(
          const ValueKey('git-branch-feature/longitudinal-shadow'),
        );
        await tester.scrollUntilVisible(tile, 200, scrollable: _page);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      },
    );

    final resetPreview = _Shot(
      'git_reset_preview_dirty',
      '커밋으로 되돌리기 미리보기',
      '수정된 파일이 있을 때 경고',
      _phone,
    );
    await _capture(
      tester,
      resetPreview,
      setup: (g) => g.dirty = true,
      act: (tester, gateway) async {
        final tile = find.byKey(
          ValueKey('git-commit-${gateway.headHistory()[4].sha}'),
        );
        await tester.scrollUntilVisible(tile, 300, scrollable: _page);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      },
    );

    final tabletPreview = _Shot(
      'git_tablet_switch_preview',
      '태블릿 · 미리보기',
      'release/stable로 바꾸기',
      _tabletLandscape,
    );
    await _capture(
      tester,
      tabletPreview,
      act: (tester, _) async {
        final tile = find.byKey(const ValueKey('git-branch-release/stable'));
        await tester.scrollUntilVisible(tile, 200, scrollable: _page);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      },
    );

    final localOnly = _Shot(
      'git_error_local_only',
      '휴대폰 연결 아직 허용 안 됨',
      '403 local_client_required',
      _phone,
    );
    await _capture(
      tester,
      localOnly,
      setup: (g) => g.mode = FakeGitMode.localOnly,
    );

    final down = _Shot(
      'git_error_no_connection',
      '연결 안 됨',
      '콤마가 답하지 않을 때',
      _phone,
    );
    await _capture(tester, down, setup: (g) => g.mode = FakeGitMode.down);

    final busy = _Shot('git_error_busy', '콤마가 바쁨', '503 git_busy', _phone);
    await _capture(tester, busy, setup: (g) => g.mode = FakeGitMode.busy);

    // Branch first: the list's note, a reset inside the current branch, a
    // detached HEAD and a commit made only on the comma.
    final branchNote = _Shot(
      'git_branch_note',
      '브랜치 목록 아래 안내',
      '다른 브랜치 커밋은 먼저 바꾼 뒤',
      _phone,
    );
    await _capture(
      tester,
      branchNote,
      act: (tester, _) async {
        final last = find.byKey(const ValueKey('git-branch-release/stable'));
        await tester.scrollUntilVisible(last, 200, scrollable: _page);
        await tester.pumpAndSettle();
        final top = tester.getRect(last).top;
        await tester.drag(_page, Offset(0, -(top - 420)));
      },
    );

    final resetHere = _Shot(
      'git_reset_preview',
      '커밋으로 되돌리기 미리보기',
      '지금 브랜치(master) 안에서만',
      _phone,
    );
    await _capture(
      tester,
      resetHere,
      act: (tester, gateway) async {
        final tile = find.byKey(
          ValueKey('git-commit-${gateway.headHistory()[4].sha}'),
        );
        await tester.scrollUntilVisible(tile, 300, scrollable: _page);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      },
    );

    final detached = _Shot(
      'git_detached',
      '브랜치 없이 커밋에 고정',
      '되돌리기 전에 브랜치로 바꾸기',
      _phone,
    );
    await _capture(
      tester,
      detached,
      setup: (g) => g
        ..head = g.headHistory()[3]
        ..branch = null
        ..upstream = null,
      act: (tester, _) async {
        final card = find.byKey(const ValueKey('git-history-card'));
        await tester.scrollUntilVisible(card, 300, scrollable: _page);
        await tester.pumpAndSettle();
        final top = tester.getRect(card).top;
        await tester.drag(_page, Offset(0, -(top - 330)));
      },
    );

    final outside = _Shot(
      'git_reset_outside',
      '콤마에만 있는 커밋',
      '브랜치 기록 밖이라 되돌릴 수 없음',
      _phone,
    );
    await _capture(
      tester,
      outside,
      setup: (g) => g.commitOnComma('wip: 콤마에서만 만든 커밋'),
      act: (tester, gateway) async {
        final tile = find.byKey(ValueKey('git-commit-${gateway.head.sha}'));
        await tester.scrollUntilVisible(tile, 300, scrollable: _page);
        await tester.pumpAndSettle();
        await tester.tap(tile);
      },
    );

    final detachedTablet = _Shot(
      'git_detached_tablet',
      '태블릿 · 브랜치 없이 고정',
      _size(_tabletLandscape),
      _tabletLandscape,
    );
    await _capture(
      tester,
      detachedTablet,
      setup: (g) => g
        ..head = g.headHistory()[3]
        ..branch = null
        ..upstream = null,
    );

    await tester.runAsync(() async {
      await _sheet('sheet_git_screens', 'KovaLink · kovapilot 버전', [
        phone,
        phoneSide,
        tablet,
        tabletTall,
      ]);
      await _sheet('sheet_git_previews', 'KovaLink · 미리보기와 오류 (적용은 꺼져 있어요)', [
        switchPreview,
        resetPreview,
        localOnly,
        busy,
      ]);
      await _sheet('sheet_git_more', 'KovaLink · 커밋 기록, 브랜치 찾기, 태블릿 미리보기', [
        phoneHistory,
        search,
        tabletPreview,
        down,
      ]);
      await _sheet('sheet_git_branch_first', 'KovaLink · 되돌리기는 지금 브랜치 안에서만', [
        branchNote,
        switchPreview,
        resetHere,
        detached,
        outside,
      ]);
    });
  });
}
