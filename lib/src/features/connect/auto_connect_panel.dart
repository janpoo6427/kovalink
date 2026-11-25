import 'package:flutter/material.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

Color autoConnectColor(AutoConnectPhase phase) => switch (phase) {
  AutoConnectPhase.connected => const Color(0xFF58F2C2),
  AutoConnectPhase.searching => const Color(0xFFFFC857),
  AutoConnectPhase.choosing => const Color(0xFF72A7FF),
  AutoConnectPhase.waiting => const Color(0xFFFF9F5A),
  AutoConnectPhase.off || AutoConnectPhase.paused => const Color(0xFF8E9DA9),
};

IconData _networkIcon(NetworkKind kind) => switch (kind) {
  NetworkKind.wifi => Icons.wifi,
  NetworkKind.hotspot => Icons.wifi_tethering,
  NetworkKind.usb => Icons.usb,
  NetworkKind.ethernet => Icons.settings_ethernet,
  NetworkKind.cellular => Icons.signal_cellular_alt,
  NetworkKind.vpn => Icons.vpn_lock_outlined,
  NetworkKind.loopback || NetworkKind.other => Icons.lan_outlined,
};

/// Small status chip on the road view: 찾는 중 · n번째 / 연결됨 / 없음.
/// As tall as the round buttons beside it (48 dp touch target); one line,
/// cut with an ellipsis only when the room the drive screen gives it
/// ([longestSize]) is too small.
class AutoConnectStatusChip extends StatelessWidget {
  const AutoConnectStatusChip({
    required this.controller,
    this.onTap,
    super.key,
  });

  final AutoConnectController controller;
  final VoidCallback? onTap;

  static const _labelStyle = TextStyle(
    color: Color(0xFF15191E),
    fontSize: 12,
    fontWeight: FontWeight.w700,
  );
  static const _padX = 14.0;
  static const _padY = 6.0;
  static const _dot = 8.0;
  static const _dotGap = 8.0;
  static const _minHeight = 48.0;

  /// Every wording [AutoConnectController.statusLabel] has, numbers at
  /// their widest: the drive screen keeps room for the longest so the chip
  /// never moves as the state changes.
  static const labelSamples = [
    '자동 연결 꺼짐',
    '자동 연결 멈춤',
    '콤마 찾는 중 · 888번째',
    '콤마 찾음 · 휴대폰 연결 아직 허용 안 됨',
    '콤마 없음 · 88초 뒤 다시',
    '콤마 88대 찾음',
    '콤마 연결됨',
  ];

  /// Size of the chip showing [label] on one line, with the text style and
  /// size it gets under [context].
  static Size sizeFor(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(_labelStyle),
      ),
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final height = 2 * _padY + painter.height.ceilToDouble();
    final size = Size(
      2 * _padX + _dot + _dotGap + painter.width.ceilToDouble(),
      height < _minHeight ? _minHeight : height,
    );
    painter.dispose();
    return size;
  }

  /// Room the chip needs for its longest wording ([labelSamples]).
  static Size longestSize(BuildContext context) {
    var width = 0.0;
    var height = 0.0;
    for (final label in labelSamples) {
      final size = sizeFor(context, label);
      if (size.width > width) width = size.width;
      if (size.height > height) height = size.height;
    }
    return Size(width, height);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final color = autoConnectColor(controller.phase);
        return Semantics(
          container: true,
          button: onTap != null,
          label: controller.statusLabel,
          child: GestureDetector(
            key: const ValueKey('auto-connect-chip'),
            onTap: onTap,
            child: LiquidGlass(
              radius: 24,
              blur: 18,
              tint: const Color(0x8CFFFFFF),
              padding: const EdgeInsets.symmetric(horizontal: _padX),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _minHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: _padY),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: _dot,
                        height: _dot,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0x6615191E)),
                        ),
                      ),
                      const SizedBox(width: _dotGap),
                      // Read out once, from the label above.
                      Flexible(
                        child: ExcludeSemantics(
                          child: Text(
                            controller.statusLabel,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: _labelStyle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Connection screen card, comma_finder style: current networks, search
/// progress, found devices and a live activity log.
class AutoConnectPanel extends StatelessWidget {
  const AutoConnectPanel({required this.controller, this.settings, super.key});

  final AutoConnectController controller;
  final SettingsController? settings;

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, ?settings]),
      builder: (context, _) {
        final c = controller;
        final color = autoConnectColor(c.phase);
        final muted = const Color(0xFF8E9DA9);
        return Card(
          key: const ValueKey('auto-connect-panel'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.radar, color: color),
                    const SizedBox(width: 10),
                    const Text(
                      '자동 연결',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        c.statusLabel,
                        key: const ValueKey('auto-connect-status'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (settings != null)
                      Switch(
                        key: const ValueKey('auto-connect-switch'),
                        value: settings.value.autoConnect,
                        onChanged: (on) =>
                            settings.update((s) => s.copyWith(autoConnect: on)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _Label('현재 네트워크'),
                if (c.networks.isEmpty)
                  Text(
                    c.phase == AutoConnectPhase.off
                        ? '자동 연결을 켜면 네트워크를 확인해요.'
                        : '연결된 와이파이·핫스팟이 없어요.',
                    style: TextStyle(color: muted, fontSize: 12),
                  )
                else
                  for (final n in c.networks)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(_networkIcon(n.kind), size: 16, color: muted),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 92,
                            child: Text(
                              n.kind.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              n.address,
                              style: const TextStyle(
                                fontSize: 13,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          Text(
                            n.scannable ? '찾아봐요' : '안 찾아요',
                            style: TextStyle(
                              fontSize: 11,
                              color: n.scannable
                                  ? const Color(0xFF58F2C2)
                                  : muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 14),
                _Label('콤마 찾기'),
                if (c.phase == AutoConnectPhase.searching) ...[
                  LinearProgressIndicator(
                    key: const ValueKey('auto-connect-progress'),
                    value: c.planned == 0 ? null : c.probed / c.planned,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  _progressLine(c),
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                if (c.found.isNotEmpty || c.device != null) ...[
                  const SizedBox(height: 14),
                  _Label('찾은 콤마'),
                  for (final d in {...c.found, ?c.device})
                    _DeviceRow(
                      device: d,
                      connected: d == c.device,
                      onChoose: c.phase == AutoConnectPhase.choosing
                          ? () => c.choose(d)
                          : null,
                    ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('auto-connect-retry'),
                      onPressed:
                          c.enabled &&
                              c.foreground &&
                              c.phase != AutoConnectPhase.searching
                          ? c.retryNow
                          : null,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('지금 찾기'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _Label('활동 로그'),
                _ActivityLog(entries: c.log),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _progressLine(AutoConnectController c) {
    final subnets = c.scanningSubnets.join(', ');
    return switch (c.phase) {
      AutoConnectPhase.off => '꺼져 있어요. 켜면 같은 와이파이나 핫스팟에서 콤마를 찾아 연결해요.',
      AutoConnectPhase.paused => '앱이 화면에 없을 때는 찾지 않아요.',
      AutoConnectPhase.searching =>
        '${c.attempt}번째 찾는 중 · ${subnets.isEmpty ? '네트워크 확인 중' : subnets} · ${c.planned}곳 중 ${c.probed}곳 확인',
      AutoConnectPhase.waiting when c.localOnly.isNotEmpty =>
        '${c.localOnly.join(', ')}: $kovaLocalOnlyMessage. 지금 kovapilot은 콤마 안에서 여는 연결만 받아요. ${c.nextRetry?.inSeconds ?? 0}초 뒤 다시 확인해요.',
      AutoConnectPhase.waiting =>
        '${c.attempt}번 찾았지만 없었어요. ${c.nextRetry?.inSeconds ?? 0}초 뒤 다시 찾아요.',
      AutoConnectPhase.choosing =>
        '콤마가 ${c.found.length}대 있어요. 연결할 기기를 골라 주세요.',
      AutoConnectPhase.connected => switch (c.device) {
        final device? when c.telemetryHeld =>
          '${device.displayName}에 연결돼 있어요. 데모를 보는 동안에는 주행 정보를 잇지 않아요.',
        final device? => '${device.displayName}에 연결돼 있어요.',
        null => '콤마에 연결돼 있어요.',
      },
    };
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: Color(0xFF58F2C2),
        letterSpacing: 0.3,
      ),
    ),
  );
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.connected,
    this.onChoose,
  });

  final KovaDevice device;
  final bool connected;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            Icons.directions_car_outlined,
            size: 18,
            color: connected
                ? const Color(0xFF58F2C2)
                : const Color(0xFF8E9DA9),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '콤마 · ${device.displayName}',
                  style: const TextStyle(fontSize: 13),
                ),
                const Text(
                  'kovapilot이 답했어요',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8E9DA9)),
                ),
              ],
            ),
          ),
          if (connected)
            const Text(
              '연결됨',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF58F2C2),
                fontWeight: FontWeight.w700,
              ),
            )
          else if (onChoose != null)
            FilledButton(
              key: ValueKey('auto-connect-choose-${device.label}'),
              onPressed: onChoose,
              child: const Text('연결'),
            ),
        ],
      ),
    );
  }
}

class _ActivityLog extends StatelessWidget {
  const _ActivityLog({required this.entries});
  final List<AutoConnectLogEntry> entries;

  static const visible = 10;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final recent = entries.reversed.take(visible).toList();
    return Container(
      key: const ValueKey('auto-connect-log'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0A1016) : const Color(0xFFF0F3F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: recent.isEmpty
          ? const Text(
              '아직 기록이 없어요.',
              style: TextStyle(fontSize: 12, color: Color(0xFF8E9DA9)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in recent)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${e.time}  ',
                            style: const TextStyle(color: Color(0xFF8E9DA9)),
                          ),
                          TextSpan(text: e.message),
                        ],
                      ),
                      style: const TextStyle(fontSize: 11.5, height: 1.35),
                    ),
                  ),
              ],
            ),
    );
  }
}
