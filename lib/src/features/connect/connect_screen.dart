import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/features/connect/comma_register_page.dart';
import 'package:kovalink/src/features/connect/ip_connect_sheet.dart';
import 'package:kovalink/src/features/connect/tailscale_vpn_card.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/readable_width.dart';
import 'package:kovalink/src/widgets/status_pill.dart';

/// 장치 연결: the Finder (commas on this Wi-Fi or hotspot), IP로 연결, the
/// registered comma, how the connections are doing and 데모 보기. Every
/// address follows the one comma found or entered ([AppSettings.endpoints]).
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({
    required this.controller,
    this.settings,
    this.autoConnect,
    this.link,
    this.pemPicker = pickPemFileWithSystemPicker,
    super.key,
  });

  final GatewayController controller;

  /// Where the found comma is remembered (the camera address follows it).
  final SettingsController? settings;

  /// 자동 연결 (network search). Optional.
  final AutoConnectController? autoConnect;

  /// Registered comma, its token and the live session. Optional (without
  /// it nothing can be registered).
  final CommaLink? link;

  /// server.pem picker for registration (tests pass a fake).
  final PemFilePicker pemPicker;

  Future<void> _register(BuildContext context, KovaDevice? device) async {
    final link = this.link;
    if (link == null) return;
    final registered = await Navigator.of(context).push<KovaDevice>(
      CommaRegisterPage.route(link: link, device: device, pemPicker: pemPicker),
    );
    if (registered != null) {
      await autoConnect?.connectTo(registered, how: '등록하고 연결');
    }
  }

  Future<void> _connectByIp(BuildContext context) async {
    final auto = autoConnect;
    if (auto == null) return;
    final outcome = await showIpConnectSheet(
      context,
      autoConnect: auto,
      link: link,
    );
    if (!context.mounted || outcome == null) return;
    if (outcome.connected case final device?) {
      await auto.connectTo(device);
    } else if (outcome.register case final device?) {
      await _register(context, device);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = this.link;
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.status,
        controller.roadStream,
        ?settings,
        ?link,
        ?autoConnect,
      ]),
      builder: (context, _) => ReadableListView(
        children: [
          const PageHeader(title: '장치 연결'),
          const SizedBox(height: 22),
          if (autoConnect case final auto?) ...[
            AutoConnectPanel(
              controller: auto,
              settings: settings,
              link: link,
              onRegister: link == null ? null : (d) => _register(context, d),
              onConnectByIp: () => _connectByIp(context),
            ),
            const SizedBox(height: 14),
          ],
          if (link != null &&
              link.session?.localNetworkPin == null &&
              (link.registered != null ||
                  (autoConnect?.found.any(
                        (device) => device.secure && !device.localNetwork,
                      ) ??
                      false))) ...[
            RegisteredCommaCard(
              link: link,
              onRegister: () => _register(context, null),
            ),
            const SizedBox(height: 14),
          ],
          if (link != null) ...[
            TailscaleVpnCard(key: ValueKey(link.registered?.pin), link: link),
            const SizedBox(height: 14),
          ],
          Card(
            key: const ValueKey('telemetry-card'),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.speed_outlined,
                        color: Color(0xFF58F2C2),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        '주행 정보',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      StatusPill(mode: controller.mode),
                    ],
                  ),
                  if (controller.errorMessage case final message?) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          controller.mode == GatewayMode.demo
                              ? '지금은 예시 주행을 보여 주고 있어요.'
                              : '차 없이 예시 주행을 볼 수 있어요.',
                          style: const TextStyle(
                            color: Color(0xFF8E9DA9),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        key: const ValueKey('connect-demo'),
                        onPressed: controller.startDemo,
                        child: const Text('데모 보기'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _CameraConnectionCard(
            controller: controller,
            signalingEndpoint: settings?.value.signalingEndpoint,
            link: link,
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '장치 등록과 카메라는 같은 네트워크에서 연결해요.',
              style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// The comma registered on this phone: its last address and certificate
/// fingerprint, 다시 등록 and 등록 지우기. The token is never shown.
class RegisteredCommaCard extends StatelessWidget {
  const RegisteredCommaCard({
    required this.link,
    required this.onRegister,
    super.key,
  });

  final CommaLink link;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final comma = link.registered;
    const muted = Color(0xFF8E9DA9);
    return Card(
      key: const ValueKey('registered-comma-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  comma == null
                      ? Icons.no_encryption_gmailerrorred_outlined
                      : Icons.verified_user_outlined,
                  color: const Color(0xFF58F2C2),
                ),
                const SizedBox(width: 10),
                const Text(
                  '등록한 콤마',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  comma == null
                      ? '없음'
                      : link.session?.sendsToken == true
                      ? '연결됨'
                      : '등록됨',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (comma == null)
              const Text(
                '아직 등록한 콤마가 없어요. 찾은 콤마의 등록을 누르거나 IP로 연결해서 등록해 주세요.',
                style: TextStyle(color: muted, fontSize: 12, height: 1.4),
              )
            else ...[
              Text(
                '콤마 · ${comma.endpoints.displayName}',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 2),
              Text(
                '인증서 지문 ${comma.pin.short}',
                key: const ValueKey('registered-comma-pin'),
                style: const TextStyle(
                  color: muted,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'IP가 바뀌어도 같은 지문의 콤마를 찾아 다시 연결해요.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  key: const ValueKey('registered-comma-register'),
                  onPressed: onRegister,
                  child: Text(comma == null ? '콤마 등록' : '다시 등록'),
                ),
                if (comma != null)
                  TextButton(
                    key: const ValueKey('registered-comma-forget'),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('등록을 지울까요?'),
                          content: const Text(
                            '휴대폰에 저장한 연결 토큰도 함께 지워요. 다시 연결하려면 다시 등록해야 해요.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('취소'),
                            ),
                            FilledButton(
                              key: const ValueKey('registered-comma-forget-ok'),
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('지우기'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) await link.forget();
                    },
                    child: const Text('등록 지우기'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraConnectionCard extends StatelessWidget {
  const _CameraConnectionCard({
    required this.controller,
    required this.signalingEndpoint,
    this.link,
  });

  final GatewayController controller;

  /// The found comma's camera address; null before a comma is found.
  final String? signalingEndpoint;
  final CommaLink? link;

  @override
  Widget build(BuildContext context) {
    final stream = controller.roadStream;
    final statusLabel = switch (stream.status) {
      RoadStreamStatus.idle => '꺼짐',
      RoadStreamStatus.connecting => '연결 중',
      RoadStreamStatus.streaming => '보는 중',
      RoadStreamStatus.error => '연결 안 됨',
    };
    final endpoint = signalingEndpoint;
    return Card(
      key: const ValueKey('camera-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.videocam_outlined, color: Color(0xFF58F2C2)),
                const SizedBox(width: 10),
                const Text(
                  '카메라',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  statusLabel,
                  style: const TextStyle(
                    color: Color(0xFF8E9DA9),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            if (stream.errorMessage case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ] else if (endpoint == null) ...[
              const SizedBox(height: 10),
              const Text(
                '콤마를 연결하면 켤 수 있어요.',
                style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('camera-on'),
                    onPressed:
                        stream.status == RoadStreamStatus.connecting ||
                            endpoint == null
                        ? null
                        : () => stream.connect(
                            signalingEndpoint: endpoint,
                            session: link?.sessionFor(endpoint),
                          ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('카메라 켜기'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: stream.disconnect,
                  child: const Text('끄기'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
