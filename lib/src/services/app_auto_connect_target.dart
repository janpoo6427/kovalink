import 'dart:async';

import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

/// What the app does once auto-connect confirms a device: for a comma on
/// Wi-Fi, open the session to the registered comma first (certificate pin,
/// then token); then remember its address, open the kovapilot settings
/// connection, and try the telemetry socket without stopping the demo when
/// telemetry is not offered. All of it goes through the one session.
class AppAutoConnectTarget implements AutoConnectTarget {
  AppAutoConnectTarget({
    required this.controller,
    required this.settings,
    required this.kovaParams,
    this.link,
  });

  final GatewayController controller;
  final SettingsController settings;
  final KovaParamsController kovaParams;

  /// Registered comma and its session; null = loopback development only.
  final CommaLink? link;

  /// Told when a comma answered but could not be used (wrong token, other
  /// certificate, refused, other version). The app wires it to
  /// [AutoConnectController.hold].
  void Function(KovaDevice device, KovaLinkProblem problem)? onProblem;

  GatewaySession? _settingsSession;

  @override
  bool get isTelemetryLive => controller.mode == GatewayMode.live;

  GatewaySession? get _session => link?.session;

  @override
  Future<void> attach(KovaDevice device, {bool openTelemetry = true}) async {
    if (link case final link?) {
      final problem = await link.open(device);
      if (problem != null) {
        onProblem?.call(device, problem);
        return;
      }
    } else if (device.secure) {
      // No way to hold a token here: never open a comma on Wi-Fi.
      onProblem?.call(device, KovaLinkProblem.needsRegistration);
      return;
    }
    settings.rememberDevice(device.host, device.port, secure: device.secure);
    _openSettings(
      device,
      force:
          kovaParams.endpoint != device.settingsEndpoint ||
          !identical(_settingsSession, _session),
    );
    if (openTelemetry) {
      await controller.connectInBackground(
        _endpoints(device).telemetry,
        session: _session,
      );
    }
  }

  @override
  Future<void> keepAlive(KovaDevice device, {bool openTelemetry = true}) async {
    _openSettings(device);
    if (openTelemetry && controller.mode != GatewayMode.live) {
      await controller.connectInBackground(
        _endpoints(device).telemetry,
        session: _session,
      );
    }
  }

  static KovapilotEndpoints _endpoints(KovaDevice device) => KovapilotEndpoints(
    host: device.host,
    port: device.port,
    secure: device.secure,
  );

  void _openSettings(KovaDevice device, {bool force = false}) {
    final status = kovaParams.status;
    if (force || status == KovaLinkStatus.disconnected) {
      final session = _session;
      _settingsSession = session;
      unawaited(
        kovaParams.connect(
          device.settingsEndpoint,
          session: session != null && session.endpoints == _endpoints(device)
              ? session
              : null,
        ),
      );
    }
  }

  @override
  void detach(KovaDevice device) {
    // The settings connection shows itself as 오래됨 and the telemetry socket
    // reports its own drop; nothing is torn down here so the last values
    // stay visible while the search runs.
  }
}

/// Tells auto-connect what happened to the telemetry socket: it went live
/// (stop searching), it was lost (look again), or the user left it on
/// purpose with 데모 보기 or a disconnect (keep the comma, do not reopen).
class TelemetryWatch {
  TelemetryWatch({required this.controller, required this.autoConnect}) {
    _wasLive = controller.mode == GatewayMode.live;
    controller.addListener(_onChange);
  }

  final GatewayController controller;
  final AutoConnectController autoConnect;
  bool _wasLive = false;

  void _onChange() {
    final mode = controller.mode;
    // A manual reconnect in progress: wait for its result.
    if (mode == GatewayMode.connecting) return;
    final live = mode == GatewayMode.live;
    if (live && !_wasLive) autoConnect.telemetryConnected();
    if (!live && _wasLive) {
      if (mode == GatewayMode.demo || mode == GatewayMode.disconnected) {
        autoConnect.telemetryLeftByUser();
      } else {
        autoConnect.connectionLost();
      }
    }
    _wasLive = live;
  }

  void dispose() => controller.removeListener(_onChange);
}
