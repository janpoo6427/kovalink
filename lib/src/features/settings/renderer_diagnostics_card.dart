import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/readable_width.dart';

/// 설정 → 앱 → 진단 entry: the one-sentence state of the road view; tap
/// opens [RendererDiagnosticsPage] with the details and 진단 복사.
class DiagnosticsEntry extends StatelessWidget {
  const DiagnosticsEntry({this.diagnostics, super.key});

  /// Defaults to [RendererDiagnostics.instance].
  final RendererDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context) {
    final diag = diagnostics ?? RendererDiagnostics.instance;
    return AnimatedBuilder(
      animation: diag,
      builder: (context, _) {
        final r = diag.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Title(),
            Card(
              child: ListTile(
                key: const ValueKey('diagnostics-entry'),
                leading: Icon(_icon(r.state), color: _tone(r.state)),
                title: Text(r.headline),
                subtitle: const Text('눌러서 자세한 내용을 보고 복사할 수 있어요.'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => KovaRoutes.open(
                  context,
                  RendererDiagnosticsPage.route(diagnostics: diagnostics),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 진단 page ([KovaRoutes.diagnostics]), opened from the settings 앱 tab.
class RendererDiagnosticsPage extends StatelessWidget {
  const RendererDiagnosticsPage({this.diagnostics, super.key});

  final RendererDiagnostics? diagnostics;

  static Route<void> route({RendererDiagnostics? diagnostics}) => KovaPageRoute(
    name: KovaRoutes.diagnostics,
    builder: (context) => KovaPage(
      backTooltip: KovaRoutes.backToSettings,
      child: RendererDiagnosticsPage(diagnostics: diagnostics),
    ),
  );

  @override
  Widget build(BuildContext context) => ReadableListView(
    children: [
      const PageHeader(title: '진단'),
      const SizedBox(height: 4),
      RendererDiagnosticsCard(diagnostics: diagnostics, showTitle: false),
    ],
  );
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(left: 4, bottom: 8, top: 18),
    child: Text(
      '진단',
      style: TextStyle(color: Color(0xFF8E9DA9), fontWeight: FontWeight.w700),
    ),
  );
}

/// 설정 → 진단: which renderer the road view uses and why, plus device
/// facts. One screenshot of this card (or the copied text) is meant to be
/// enough to diagnose a blank road view on a phone.
class RendererDiagnosticsCard extends StatefulWidget {
  const RendererDiagnosticsCard({
    this.diagnostics,
    this.showTitle = true,
    super.key,
  });

  /// Defaults to [RendererDiagnostics.instance].
  final RendererDiagnostics? diagnostics;

  /// The small 진단 section title above the card (off on the 진단 page,
  /// which has its own page title).
  final bool showTitle;

  @override
  State<RendererDiagnosticsCard> createState() =>
      _RendererDiagnosticsCardState();
}

class _RendererDiagnosticsCardState extends State<RendererDiagnosticsCard> {
  RendererDiagnostics get _diag =>
      widget.diagnostics ?? RendererDiagnostics.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_diag.loadDevice());
    unawaited(_diag.refreshNativeLog());
  }

  Future<void> _copy() async {
    await _diag.refreshNativeLog();
    final text = _diag.value.toText();
    await Clipboard.setData(ClipboardData(text: text));
    RendererDiagnostics.log('진단 복사\n$text');
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('진단 내용을 복사했어요.')));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _diag,
      builder: (context, _) {
        final r = _diag.value;
        final recent = r.events.length > 6
            ? r.events.sublist(r.events.length - 6)
            : r.events;
        final explanation = r.explanation;
        return Column(
          key: const ValueKey('renderer-diagnostics'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showTitle) const _Title(),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2, right: 10),
                          child: Icon(
                            _icon(r.state),
                            size: 20,
                            color: _tone(r.state),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            r.headline,
                            key: const ValueKey('diagnostics-headline'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (explanation.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 30, top: 6),
                        child: Text(
                          explanation,
                          key: const ValueKey('diagnostics-explanation'),
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: Color(0xFFD3DCE4),
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        '자세한 내용',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF8E9DA9),
                        ),
                      ),
                    ),
                    _Row('지금 화면', rendererStateLabel(r.state)),
                    _Row('바꾼 이유', r.reason ?? '없음'),
                    _Row('화질 설정', r.quality),
                    _Row('연결 방식', '${r.textureSource} (${r.attempt + 1}번째 시도)'),
                    _Row('화면 점검', r.probe),
                    _Row('3D 그림', r.frames?.describe ?? '-'),
                    _Row('휴대폰', r.deviceLine),
                    _Row('GPU', r.gpuLine),
                    _Row('앱 빌드', RendererDiagnostics.build),
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      for (final e in recent)
                        Text(
                          '$e',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB5C0CB),
                          ),
                        ),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        key: const ValueKey('diagnostics-copy'),
                        onPressed: _copy,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('진단 복사'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

IconData _icon(RendererState state) => switch (state) {
  RendererState.gpu => Icons.check_circle_rounded,
  RendererState.checking => Icons.hourglass_top_rounded,
  RendererState.fallback => Icons.info_rounded,
  RendererState.software => Icons.layers_rounded,
};

Color _tone(RendererState state) => switch (state) {
  RendererState.gpu => const Color(0xFF58F2C2),
  RendererState.checking => const Color(0xFF8EC5FF),
  RendererState.fallback => const Color(0xFFFFC266),
  RendererState.software => const Color(0xFFB5C0CB),
};

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );
}
