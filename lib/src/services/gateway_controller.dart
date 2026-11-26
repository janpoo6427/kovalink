import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';

import "package:kovalink/src/services/live_lane_filter.dart";

enum GatewayMode { demo, connecting, live, disconnected, error }

/// Opens a telemetry WebSocket (tests replace the network).
typedef WebSocketConnector = Future<WebSocket> Function(String url);

class GatewayController extends ChangeNotifier {
  GatewayController({WebSocketConnector? webSocketConnector})
    : _connectSocket = webSocketConnector ?? ((url) => WebSocket.connect(url));

  final WebSocketConnector _connectSocket;
  final _laneFilter = LiveLaneFilter();
  bool _backgroundAttempt = false;

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

  /// Notifies when the connection changes (mode, error, address, sign-in,
  /// demo route) but not on every telemetry frame. Pages that show the
  /// connection and not the road listen to this instead of the controller.
  Listenable get status => _status;
  final _status = _StatusNotifier();
  Object? _lastStatus;

  @override
  void notifyListeners() {
    super.notifyListeners();
    final now = (
      mode,
      errorMessage,
      connectedEndpoint,
      gatewayAuthenticated,
      demoRoute,
    );
    if (now == _lastStatus) return;
    _lastStatus = now;
    _status.changed();
  }

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

  /// Opens telemetry at [endpoint]. A comma on Wi-Fi goes through
  /// [session] (pinned client, token); a loopback development gateway is
  /// opened directly.
  Future<String?> connect(String endpoint, {GatewaySession? session}) async {
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
      final socket = await _open(
        endpoint.trim(),
        session,
      ).timeout(const Duration(seconds: 5));
      _attach(socket, endpoint.trim(), authenticated: _authenticated(session));
      return null;
    } on Object {
      _handleDisconnect('차에 연결할 수 없어요. 주소와 네트워크를 확인해 주세요.');
      return errorMessage;
    }
  }

  /// Auto-connect: tries [endpoint] without touching the current state (the
  /// demo keeps playing, no error is shown) and switches to live only when
  /// the socket opens. Returns true when live.
  ///
  /// With a [session] (the registered comma on Wi-Fi) a live socket to
  /// another address is replaced once the new one is open: the comma got a
  /// new IP, and its old socket can stay half-open for a long time after
  /// the old address is gone.
  Future<bool> connectInBackground(
    String endpoint, {
    GatewaySession? session,
  }) async {
    final moved =
        mode == GatewayMode.live &&
        session != null &&
        connectedEndpoint != endpoint.trim();
    if (mode == GatewayMode.live && !moved) return true;
    if (mode == GatewayMode.connecting || _backgroundAttempt) return false;
    if (LocalEndpointPolicy.validate(endpoint) != null) return false;
    _backgroundAttempt = true;
    try {
      final socket = await _open(
        endpoint.trim(),
        session,
      ).timeout(const Duration(seconds: 5));
      if (mode == GatewayMode.connecting ||
          (mode == GatewayMode.live && !moved)) {
        // A manual connection started meanwhile; keep that one.
        unawaited(socket.close());
        return mode == GatewayMode.live;
      }
      _closeTransport();
      errorMessage = null;
      _attach(socket, endpoint.trim(), authenticated: _authenticated(session));
      return true;
    } on Object {
      return false;
    } finally {
      _backgroundAttempt = false;
    }
  }

  /// A Wi-Fi URL only opens through a session that checks its certificate.
  Future<WebSocket> _open(String url, GatewaySession? session) {
    final uri = Uri.parse(url);
    if (session != null && !session.isClosed && session.covers(uri)) {
      return session.openWebSocket(url);
    }
    if (uri.scheme == 'wss' && !LocalEndpointPolicy.isLoopbackHost(uri.host)) {
      return Future.error(const SocketException('no session for this comma'));
    }
    return _connectSocket(url);
  }

  static bool _authenticated(GatewaySession? session) =>
      session?.wifiAuthentication != null;

  void _attach(
    WebSocket socket,
    String endpoint, {
    bool authenticated = false,
  }) {
    _laneFilter.reset();
    _socket = socket;
    connectedEndpoint = endpoint;
    gatewayAuthenticated = authenticated;
    mode = GatewayMode.live;
    _socketSubscription = socket.listen(
      _handleMessage,
      onDone: () => _handleDisconnect('차와 연결이 끊겼어요.'),
      onError: (Object error) => _handleDisconnect('차와 연결이 끊겼어요. 다시 연결해 주세요.'),
      cancelOnError: true,
    );
    notifyListeners();
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
      scene = RoadScene.fromJson(_laneFilter.apply(decoded));
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
    _status.dispose();
    super.dispose();
  }
}

class _StatusNotifier extends ChangeNotifier {
  void changed() => notifyListeners();
}
