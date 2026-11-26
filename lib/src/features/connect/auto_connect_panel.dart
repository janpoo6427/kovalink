import 'package:flutter/material.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

Color autoConnectColor(AutoConnectPhase phase) => switch (phase) {
  AutoConnectPhase.connected => const Color(0xFF58F2C2),
  AutoConnectPhase.searching => const Color(0xFFFFC857),
  AutoConnectPhase.choosing => const Color(0xFF72A7FF),
  AutoConnectPhase.waiting => const Color(0xFFFF9F5A),
  AutoConnectPhase.needsAttention => const Color(0xFFFF6B72),
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
class AutoConnectStatusChip extends StatelessWidget {
  const AutoConnectStatusChip({
    required this.controller,
    this.onTap,
    super.key,
  });

  final AutoConnectController controller;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final color = autoConnectColor(controller.phase);
        return Semantics(
          button: onTap != null,
          label: controller.statusLabel,
          child: GestureDetector(
            key: const ValueKey('auto-connect-chip'),
            onTap: onTap,
            child: LiquidGlass(
              radius: 24,
              blur: 18,
              tint: const Color(0x8CFFFFFF),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0x6615191E)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      controller.statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF15191E),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The Finder on the connection screen, comma_finder style: current
/// networks, search progress, the commas found on this Wi-Fi or hotspot
/// (connect the registered one, register a new one), 지금 찾기, IP로 연결
/// and a live activity log.
class AutoConnectPanel extends StatelessWidget {
  const AutoConnectPanel({
    required this.controller,
    this.settings,
    this.link,
    this.onRegister,
    this.onConnectByIp,
    super.key,
  });

  final AutoConnectController controller;
  final SettingsController? settings;

  /// The registered comma and the live connection (problems, 등록됨).
  final CommaLink? link;

  /// Opens registration for a comma that is not registered yet.
  final void Function(KovaDevice device)? onRegister;

  /// Opens IP entry. Null hides the button.
  final VoidCallback? onConnectByIp;

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    final link = this.link;
    final onRegister = this.onRegister;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, ?settings, ?link]),
      builder: (context, _) {
        final c = controller;
        final color = autoConnectColor(c.phase);
        const muted = Color(0xFF8E9DA9);
        final problem = c.problem ?? link?.problem;
        final devices = {...c.found, ?c.device};
        final nothingFound =
            devices.isEmpty &&
            (c.phase == AutoConnectPhase.waiting ||
                c.phase == AutoConnectPhase.needsAttention ||
                c.phase == AutoConnectPhase.off);
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
                    style: const TextStyle(color: muted, fontSize: 12),
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
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                if (problem != null &&
                    c.phase != AutoConnectPhase.searching) ...[
                  const SizedBox(height: 10),
                  LinkProblemNote(problem: problem),
                ],
                if (devices.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _Label('찾은 콤마'),
                  for (final d in devices)
                    _DeviceRow(
                      device: d,
                      connected: d == c.device,
                      registered:
                          !d.secure ||
                          (link?.registered?.isPresentedBy(d) ?? false),
                      onChoose:
                          c.phase == AutoConnectPhase.choosing && c.canAttach(d)
                          ? () => c.choose(d)
                          : null,
                      onRetry:
                          c.phase == AutoConnectPhase.needsAttention &&
                              c.canAttach(d) &&
                              problem != KovaLinkProblem.tokenRejected
                          ? () => c.connectTo(d, how: '다시 연결')
                          : null,
                      onRegister:
                          onRegister != null &&
                              !d.localNetwork &&
                              d != c.device &&
                              (!c.canAttach(d) ||
                                  problem == KovaLinkProblem.tokenRejected ||
                                  problem == KovaLinkProblem.needsToken)
                          ? () => onRegister(d)
                          : null,
                    ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    if (onConnectByIp case final byIp? when nothingFound)
                      FilledButton.icon(
                        key: const ValueKey('connect-by-ip'),
                        onPressed: byIp,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                        ),
                        icon: const Icon(Icons.dialpad, size: 20),
                        label: const Text(
                          'IP로 연결',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
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
                    if (onConnectByIp case final byIp? when !nothingFound)
                      OutlinedButton.icon(
                        key: const ValueKey('connect-by-ip'),
                        onPressed: byIp,
                        icon: const Icon(Icons.dialpad, size: 18),
                        label: const Text('IP로 연결'),
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
        c.found.any(c.canAttach)
            ? '콤마가 ${c.found.length}대 있어요. 연결할 기기를 골라 주세요.'
            : '콤마를 찾았어요. 눌러서 등록하면 연결할 수 있어요.',
      AutoConnectPhase.needsAttention => '콤마가 답했지만 연결을 이어 가지 못했어요.',
      AutoConnectPhase.connected => switch (c.device) {
        final device? when c.telemetryHeld =>
          '${device.displayName}에 연결돼 있어요. 데모를 보는 동안에는 주행 정보를 잇지 않아요.',
        final device? => '${device.displayName}에 연결돼 있어요.',
        null => '콤마에 연결돼 있어요.',
      },
    };
  }
}

/// One problem line in plain words, with the longer explanation folded.
class LinkProblemNote extends StatefulWidget {
  const LinkProblemNote({required this.problem, super.key});

  final KovaLinkProblem problem;

  @override
  State<LinkProblemNote> createState() => _LinkProblemNoteState();
}

class _LinkProblemNoteState extends State<LinkProblemNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final serious = switch (widget.problem) {
      KovaLinkProblem.tokenRejected ||
      KovaLinkProblem.identityMismatch ||
      KovaLinkProblem.notAllowed ||
      KovaLinkProblem.versionMismatch ||
      KovaLinkProblem.needsToken => true,
      _ => false,
    };
    final color = serious ? const Color(0xFFFF6B72) : const Color(0xFFFFC857);
    return Container(
      key: ValueKey('link-problem-${widget.problem.name}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                serious ? Icons.error_outline : Icons.info_outline,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  KovaLinkText.message(widget.problem),
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ),
            ],
          ),
          TextButton(
            key: const ValueKey('link-problem-more'),
            onPressed: () => setState(() => _open = !_open),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              minimumSize: const Size(0, 32),
            ),
            child: Text(_open ? '접기' : '자세히 보기'),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 0, 8),
              child: Text(
                KovaLinkText.detail(widget.problem),
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Color(0xFF8E9DA9),
                ),
              ),
            ),
        ],
      ),
    );
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
    required this.registered,
    this.onChoose,
    this.onRetry,
    this.onRegister,
  });

  final KovaDevice device;
  final bool connected;
  final bool registered;
  final VoidCallback? onChoose;
  final VoidCallback? onRetry;
  final VoidCallback? onRegister;

  @override
  Widget build(BuildContext context) {
    final subtitle = device.localNetwork
        ? '같은 네트워크에서 연결 가능'
        : !device.secure
        ? 'kovapilot이 답했어요'
        : registered
        ? '등록한 콤마예요'
        : '등록하면 연결할 수 있어요';
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
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8E9DA9),
                  ),
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
            )
          else if (onRetry != null)
            OutlinedButton(
              key: ValueKey('auto-connect-retry-${device.label}'),
              onPressed: onRetry,
              child: const Text('다시 연결'),
            ),
          if (onRegister != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: ValueKey('auto-connect-register-${device.label}'),
              onPressed: onRegister,
              child: Text(registered ? '다시 등록' : '등록'),
            ),
          ],
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
