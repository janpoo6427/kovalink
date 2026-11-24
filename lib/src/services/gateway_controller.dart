import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';

enum GatewayMode { demo, connecting, live, disconnected, error }

class GatewayController extends ChangeNotifier {
  final WebRtcRoadStream roadStream = WebRtcRoadStream();
  GatewayMode mode = GatewayMode.disconnected;
  RoadScene scene = RoadScene.demo(Duration.zero);
  String? errorMessage;
  String? connectedEndpoint;
  bool gatewayAuthenticated = false;

  Timer? _demoTimer;
  Stopwatch? _demoClock;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;

  bool get canEditSettings => mode == GatewayMode.live && gatewayAuthenticated;

  void startDemo() {
    _closeTransport();
    errorMessage = null;
    connectedEndpoint = null;
    gatewayAuthenticated = false;
    mode = GatewayMode.demo;
    _demoClock = Stopwatch()..start();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      scene = RoadScene.demo(_demoClock!.elapsed);
      notifyListeners();
    });
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
        onDone: () => _handleDisconnect('gateway 연결이 종료되었습니다.'),
        onError: (Object error) => _handleDisconnect('gateway 통신 오류: $error'),
        cancelOnError: true,
      );
      notifyListeners();
      return null;
    } on Object catch (error) {
      _handleDisconnect('gateway에 연결할 수 없습니다: $error');
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
    } on Object catch (error) {
      errorMessage = '잘못된 telemetry frame: $error';
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
    _demoClock?.stop();
    _demoClock = null;
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
