import 'dart:async';

import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

/// What the app does once auto-connect confirms a device: remember its
/// address, open the kovapilot settings connection, and try the telemetry
/// socket without stopping the demo when telemetry is not offered.
class AppAutoConnectTarget implements AutoConnectTarget {
  AppAutoConnectTarget({
    required this.controller,
    required this.settings,
    required this.kovaParams,
  });

  final GatewayController controller;
  final SettingsController settings;
  final KovaParamsController kovaParams;

  @override
  bool get isTelemetryLive => controller.mode == GatewayMode.live;

  @override
  Future<void> attach(KovaDevice device, {bool openTelemetry = true}) async {
    settings.rememberDevice(device.host, device.port);
    _openSettings(
      device,
      force: kovaParams.endpoint != device.settingsEndpoint,
    );
    if (openTelemetry) {
      await controller.connectInBackground(settings.value.telemetryEndpoint);
    }
  }

  @override
  Future<void> keepAlive(KovaDevice device, {bool openTelemetry = true}) async {
    _openSettings(device);
    if (openTelemetry && controller.mode != GatewayMode.live) {
      await controller.connectInBackground(settings.value.telemetryEndpoint);
    }
  }

  void _openSettings(KovaDevice device, {bool force = false}) {
    final status = kovaParams.status;
    if (force || status == KovaLinkStatus.disconnected) {
      unawaited(kovaParams.connect(device.settingsEndpoint));
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
