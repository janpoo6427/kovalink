import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/readable_width.dart';
import 'package:kovalink/src/widgets/status_pill.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    required this.controller,
    this.settings,
    this.autoConnect,
    super.key,
  });

  final GatewayController controller;

  /// Saved device addresses (설정 → 연결 장치 주소). Optional.
  final SettingsController? settings;

  /// 자동 연결 (network search). Optional.
  final AutoConnectController? autoConnect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final endpointController = TextEditingController(
    text:
        widget.settings?.value.telemetryEndpoint ??
        AppSettings.defaultTelemetryEndpoint,
  );
  late final cameraEndpointController = TextEditingController(
    text:
        widget.settings?.value.signalingEndpoint ??
        AppSettings.defaultSignalingEndpoint,
  );

  @override
  void initState() {
    super.initState();
    _savedTelemetry = widget.settings?.value.telemetryEndpoint;
    _savedSignaling = widget.settings?.value.signalingEndpoint;
    widget.settings?.addListener(_followSavedAddresses);
  }

  String? _savedTelemetry;
  String? _savedSignaling;

  /// Auto-connect moves the saved addresses to the device it found. Follow
  /// them unless the user has typed something else.
  void _followSavedAddresses() {
    final value = widget.settings!.value;
    if (value.telemetryEndpoint != _savedTelemetry) {
      if (endpointController.text.trim() == _savedTelemetry) {
        endpointController.text = value.telemetryEndpoint;
      }
      _savedTelemetry = value.telemetryEndpoint;
    }
    if (value.signalingEndpoint != _savedSignaling) {
      if (cameraEndpointController.text.trim() == _savedSignaling) {
        cameraEndpointController.text = value.signalingEndpoint;
      }
      _savedSignaling = value.signalingEndpoint;
    }
  }

  @override
  void dispose() {
    widget.settings?.removeListener(_followSavedAddresses);
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
      builder: (context, _) => ReadableListView(
        children: [
          const PageHeader(title: '장치 연결'),
          const SizedBox(height: 22),
          if (widget.autoConnect case final auto?) ...[
            AutoConnectPanel(controller: auto, settings: widget.settings),
            const SizedBox(height: 14),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '주행 정보',
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
                      labelText: '주소',
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
                              : () {
                                  // Remember a valid local address; the
                                  // policy check also runs in connect().
                                  widget.settings?.setTelemetryEndpoint(
                                    endpointController.text,
                                  );
                                  widget.controller.connect(
                                    endpointController.text,
                                  );
                                },
                          icon: const Icon(Icons.link),
                          label: const Text('연결'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: widget.controller.startDemo,
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
            controller: widget.controller,
            endpointController: cameraEndpointController,
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
    required this.endpointController,
  });

  final GatewayController controller;
  final TextEditingController endpointController;

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
            const SizedBox(height: 14),
            TextField(
              controller: endpointController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '주소',
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
