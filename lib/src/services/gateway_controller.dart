import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';

enum GatewayMode { demo, connecting, live, disconnected, error }

class GatewayController extends ChangeNotifier {
  final WebRtcRoadStream roadStream = WebRtcRoadStream();
  GatewayMode mode = GatewayMode.disconnected;
  RoadScene scene = DemoDriveScenario().sceneAt(Duration.zero);
  String? errorMessage;
  String? connectedEndpoint;
  bool gatewayAuthenticated = false;

  /// Demo route currently (or last) played.
  DemoRoute demoRoute = DemoRoute.city;

  static const demoFrameInterval = Duration(milliseconds: 50);

  Timer? _demoTimer;
  DemoDriveScenario? _scenario;
  Duration _demoElapsed = Duration.zero;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;

  bool get canEditSettings => mode == GatewayMode.live && gatewayAuthenticated;

  /// Elapsed demo time. Advances by exactly one frame interval per tick so
  /// the demo is deterministic (independent of wall-clock jitter).
  Duration get demoElapsed => _demoElapsed;

  /// The scenario being played, or null when the demo is off.
  DemoDriveScenario? get scenario => _scenario;

  /// Plays the built-in demo drive. No network is used.
  void startDemo({DemoRoute? route, int seed = DemoDriveScenario.defaultSeed}) {
    _closeTransport();
    errorMessage = null;
    connectedEndpoint = null;
    gatewayAuthenticated = false;
    mode = GatewayMode.demo;
    demoRoute = route ?? demoRoute;
    final scenario = DemoDriveScenario(route: demoRoute, seed: seed);
    _scenario = scenario;
    _demoElapsed = Duration.zero;
    scene = scenario.sceneAt(_demoElapsed);
    _demoTimer = Timer.periodic(demoFrameInterval, (_) {
      _demoElapsed += demoFrameInterval;
      scene = scenario.sceneAt(_demoElapsed);
      notifyListeners();
    });
    notifyListeners();
  }

  /// Stops the demo and shows an idle road (no vehicles, standby state).
  void stopDemo() {
    if (mode != GatewayMode.demo) return;
    _closeTransport();
    mode = GatewayMode.disconnected;
    scene = RoadScene.idle;
    notifyListeners();
  }

  Future<String?> connect(String endpoint) async {
    final validationError = LocalEndpointPolicy.validate(endpoint);
    if (validationError != null) {
      errorMessage = validationError;
      mode = GatewayMode.error;
      notifyListeners();
      return validationError;
    }

    _closeTransport();
    mode = GatewayMode.connecting;
    errorMessage = null;
    notifyListeners();
    try {
      final socket = await WebSocket.connect(
        endpoint.trim(),
      ).timeout(const Duration(seconds: 5));
      _socket = socket;
      connectedEndpoint = endpoint.trim();
      gatewayAuthenticated = false;
      mode = GatewayMode.live;
      _socketSubscription = socket.listen(
        _handleMessage,
        onDone: () => _handleDisconnect('차와 연결이 끊겼어요.'),
        onError: (Object error) =>
            _handleDisconnect('차와 연결이 끊겼어요. 다시 연결해 주세요.'),
        cancelOnError: true,
      );
      notifyListeners();
      return null;
    } on Object {
      _handleDisconnect('차에 연결할 수 없어요. 주소와 네트워크를 확인해 주세요.');
      return errorMessage;
    }
  }

  void disconnect() {
    _closeTransport();
    mode = GatewayMode.disconnected;
    errorMessage = null;
    connectedEndpoint = null;
    gatewayAuthenticated = false;
    notifyListeners();
  }

  void _handleMessage(dynamic value) {
    try {
      final text = switch (value) {
        String data => data,
        List<int> data => utf8.decode(data),
        _ => throw const FormatException('지원하지 않는 WebSocket frame'),
      };
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('telemetry frame은 JSON object여야 합니다.');
      }
      scene = RoadScene.fromJson(decoded);
      notifyListeners();
    } on Object {
      errorMessage = '차에서 받은 주행 정보를 읽을 수 없어요.';
      notifyListeners();
    }
  }

  void _handleDisconnect(String message) {
    _closeTransport(closeSocket: false);
    mode = GatewayMode.error;
    errorMessage = message;
    connectedEndpoint = null;
    gatewayAuthenticated = false;
    notifyListeners();
  }

  void _closeTransport({bool closeSocket = true}) {
    _demoTimer?.cancel();
    _demoTimer = null;
    _scenario = null;
    _socketSubscription?.cancel();
    _socketSubscription = null;
    if (closeSocket) _socket?.close();
    _socket = null;
  }

  @override
  void dispose() {
    _closeTransport();
    roadStream.dispose();
    super.dispose();
  }
}
