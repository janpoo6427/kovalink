import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/readable_width.dart';
import 'package:kovalink/src/widgets/status_pill.dart';

/// 장치 연결: the comma 자동 연결 found, how the connections are doing, 지금
/// 찾기 and 데모 보기. There is no address to type: KovaLink only talks to
/// kovapilot, at the comma 자동 연결 found ([AppSettings.endpoints]).
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({
    required this.controller,
    this.settings,
    this.autoConnect,
    super.key,
  });

  final GatewayController controller;

  /// Where the found comma is remembered (the camera address follows it).
  final SettingsController? settings;

  /// 자동 연결 (network search). Optional.
  final AutoConnectController? autoConnect;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([controller, controller.roadStream]),
      builder: (context, _) => ReadableListView(
        children: [
          const PageHeader(title: '장치 연결'),
          const SizedBox(height: 22),
          if (autoConnect case final auto?) ...[
            AutoConnectPanel(controller: auto, settings: settings),
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
            signalingEndpoint:
                settings?.value.signalingEndpoint ??
                AppSettings.defaultSignalingEndpoint,
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '차와 같은 네트워크에서만 연결하고, comma 클라우드는 쓰지 않아요.',
              style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraConnectionCard extends StatelessWidget {
  const _CameraConnectionCard({
    required this.controller,
    required this.signalingEndpoint,
  });

  final GatewayController controller;

  /// The found comma's camera address.
  final String signalingEndpoint;

  @override
  Widget build(BuildContext context) {
    final stream = controller.roadStream;
    final statusLabel = switch (stream.status) {
      RoadStreamStatus.idle => '꺼짐',
      RoadStreamStatus.connecting => '연결 중',
      RoadStreamStatus.streaming => '보는 중',
      RoadStreamStatus.error => '연결 안 됨',
    };
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
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('camera-on'),
                    onPressed: stream.status == RoadStreamStatus.connecting
                        ? null
                        : () => stream.connect(
                            signalingEndpoint: signalingEndpoint,
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
