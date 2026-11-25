import 'package:flutter/foundation.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

/// Every address KovaLink opens. KovaLink only talks to kovapilot, so none
/// of them is typed in: the host is the comma that 자동 연결 found
/// (`comma.local` until then) and the port and paths are kovapilot's:
///
/// - settings: `http://<host>:8082`
/// - telemetry: `ws://<host>:8082/v1/telemetry`
/// - camera: `http://<host>:8082/v1/stream`
///
/// Tests and e2e runs point the app elsewhere with code arguments only
/// (a found device on another port, `GatewayController.connect`,
/// `KovaParamsController.connect`); there is no address field on screen.
@immutable
class KovapilotEndpoints {
  const KovapilotEndpoints({
    this.host = defaultHost,
    this.port = kovaGatewayDefaultPort,
  });

  /// From the settings origin of a found device (`http://host:port`), or
  /// the `comma.local` default when there is none or the local-only policy
  /// refuses it.
  factory KovapilotEndpoints.fromOrigin(String? origin) {
    if (origin == null ||
        LocalEndpointPolicy.validateSettings(origin) != null) {
      return const KovapilotEndpoints();
    }
    final uri = LocalEndpointPolicy.settingsBase(origin);
    return KovapilotEndpoints(
      host: uri.host,
      port: uri.hasPort ? uri.port : kovaGatewayDefaultPort,
    );
  }

  static const defaultHost = 'comma.local';
  static const telemetryPath = '/v1/telemetry';
  static const streamPath = '/v1/stream';

  final String host;
  final int port;

  /// kovapilot settings HTTP origin (`/v1/kova-params` is appended).
  String get settings => Uri(scheme: 'http', host: host, port: port).toString();

  String get telemetry =>
      Uri(scheme: 'ws', host: host, port: port, path: telemetryPath).toString();

  /// Camera (WebRTC signaling).
  String get signaling =>
      Uri(scheme: 'http', host: host, port: port, path: streamPath).toString();

  @override
  bool operator ==(Object other) =>
      other is KovapilotEndpoints && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'KovapilotEndpoints($settings)';
}
