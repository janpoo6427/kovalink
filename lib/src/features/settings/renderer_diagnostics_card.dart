import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/features/road_view/renderer_diagnostics.dart';

/// 설정 → 진단: which renderer the road view uses and why, plus device
/// facts. One screenshot of this card (or the copied text) is meant to be
/// enough to diagnose a blank road view on a phone.
class RendererDiagnosticsCard extends StatefulWidget {
  const RendererDiagnosticsCard({this.diagnostics, super.key});

  /// Defaults to [RendererDiagnostics.instance].
  final RendererDiagnostics? diagnostics;

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
        return Column(
          key: const ValueKey('renderer-diagnostics'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 8, top: 18),
              child: Text(
                '진단',
                style: TextStyle(
                  color: Color(0xFF8E9DA9),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Row('렌더러', rendererStateLabel(r.state)),
                    _Row('전환 이유', r.reason ?? '없음'),
                    _Row('화질 설정', r.quality),
                    _Row('텍스처', '${r.textureSource} (시도 ${r.attempt + 1})'),
                    _Row('화면 확인', r.probe),
                    _Row('기기', r.deviceLine),
                    _Row('GPU', r.gpuLine),
                    _Row('빌드', RendererDiagnostics.build),
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
