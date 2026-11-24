import 'package:flutter/material.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/status_pill.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({required this.controller, super.key});

  final GatewayController controller;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final endpointController = TextEditingController(
    text: 'ws://comma.local:8082/v1/telemetry',
  );
  final cameraEndpointController = TextEditingController(
    text: 'http://comma.local:8082/v1/stream',
  );

  @override
  void dispose() {
    endpointController.dispose();
    cameraEndpointController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.controller.roadStream,
      ]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          const PageHeader(
            title: '장치 연결',
            subtitle: '로컬 네트워크에서만 comma gateway와 통신합니다.',
          ),
          const SizedBox(height: 22),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '현재 상태',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      StatusPill(mode: widget.controller.mode),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: endpointController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Gateway WebSocket',
                      hintText: 'wss://comma.local/v1/telemetry',
                    ),
                  ),
                  if (widget.controller.errorMessage case final message?) ...[
                    const SizedBox(height: 10),
                    Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              widget.controller.mode == GatewayMode.connecting
                              ? null
                              : () => widget.controller.connect(
                                  endpointController.text,
                                ),
                          icon: const Icon(Icons.link),
                          label: const Text('로컬 연결'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: widget.controller.startDemo,
                        child: const Text('데모'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _CameraConnectionCard(
            controller: widget.controller,
            endpointController: cameraEndpointController,
          ),
          const SizedBox(height: 14),
          const _PrivacyCard(
            icon: Icons.lan_outlined,
            title: 'Local only',
            body: '공인 IP와 공개 도메인은 연결 정책에서 거부합니다.',
          ),
          const _PrivacyCard(
            icon: Icons.cloud_off_outlined,
            title: 'No comma cloud',
            body: 'Athena 또는 comma route upload를 사용하지 않습니다.',
          ),
          const _PrivacyCard(
            icon: Icons.visibility_outlined,
            title: 'Read-only first',
            body: 'pairing 전에는 telemetry 조회만 허용하도록 설계합니다.',
          ),
        ],
      ),
    );
  }
}

class _CameraConnectionCard extends StatelessWidget {
  const _CameraConnectionCard({
    required this.controller,
    required this.endpointController,
  });

  final GatewayController controller;
  final TextEditingController endpointController;

  @override
  Widget build(BuildContext context) {
    final stream = controller.roadStream;
    final statusLabel = switch (stream.status) {
      RoadStreamStatus.idle => '대기',
      RoadStreamStatus.connecting => '연결 중',
      RoadStreamStatus.streaming => '영상 수신 중',
      RoadStreamStatus.error => '연결 오류',
    };
    return Card(
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
                  'Road camera',
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
            const SizedBox(height: 14),
            TextField(
              controller: endpointController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'WebRTC signaling',
                hintText: 'https://comma.local:8082/v1/stream',
              ),
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
                    onPressed: stream.status == RoadStreamStatus.connecting
                        ? null
                        : () => stream.connect(
                            signalingEndpoint: endpointController.text,
                          ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('스트림 시작'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: stream.disconnect,
                  child: const Text('중지'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(body),
      ),
    );
  }
}
