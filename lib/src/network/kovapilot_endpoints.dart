import 'package:flutter/foundation.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

/// Every address KovaLink opens on one comma, built from that comma's one
/// origin (scheme, host, port). None of them is typed in: the comma is the
/// one the Finder found or the user entered by IP.
///
/// - Wi-Fi ([secure]): `https://<IP>:8082` for settings, Git and health,
///   `wss://<IP>:8082/v1/telemetry`, `https://<IP>:8082/v1/stream`.
/// - Loopback (development on the same machine): the same paths on
///   `http://127.0.0.1:8082` and `ws://`.
///
/// Only hosts the local-only policy accepts are used: loopback, `.local`,
/// private IPv4, link-local and unique-local IPv6.
@immutable
class KovapilotEndpoints {
  const KovapilotEndpoints({
    required this.host,
    this.port = kovaGatewayDefaultPort,
    this.secure = false,
  });

  /// The comma at [host]:[port]: TLS unless the host is loopback.
  factory KovapilotEndpoints.device(
    String host, [
    int port = kovaGatewayDefaultPort,
  ]) => KovapilotEndpoints(
    host: host,
    port: port,
    secure: !LocalEndpointPolicy.isLoopbackHost(host),
  );

  /// From a stored origin (`https://192.168.43.20:8082`), keeping its
  /// scheme. Null when there is none or the local-only policy refuses it.
  static KovapilotEndpoints? fromOrigin(String? origin) {
    if (origin == null ||
        LocalEndpointPolicy.validateSettings(origin) != null) {
      return null;
    }
    final uri = LocalEndpointPolicy.settingsBase(origin);
    final secure = uri.scheme == 'https';
    return KovapilotEndpoints(
      host: uri.host,
      port: uri.hasPort ? uri.port : (secure ? 443 : 80),
      secure: secure,
    );
  }

  static const healthPath = '/v1/health';
  static const kovaParamsPath = '/v1/kova-params';
  static const kovaParamsUpdatePath = '/v1/kova-params/update';
  static const telemetryPath = '/v1/telemetry';
  static const streamPath = '/v1/stream';
  static const gitPathPrefix = '/v1/git/';

  final String host;
  final int port;

  /// Wi-Fi: HTTPS/WSS with the comma's certificate pin and token.
  final bool secure;

  String get _http => secure ? 'https' : 'http';
  String get _ws => secure ? 'wss' : 'ws';

  /// HTTP origin, e.g. `https://192.168.43.20:8082`.
  String get origin => Uri(scheme: _http, host: host, port: port).toString();

  /// kovapilot settings origin (`/v1/kova-params` is appended).
  String get settings => origin;

  String get telemetry =>
      Uri(scheme: _ws, host: host, port: port, path: telemetryPath).toString();

  /// Camera (WebRTC signaling).
  String get signaling =>
      Uri(scheme: _http, host: host, port: port, path: streamPath).toString();

  Uri get health =>
      Uri(scheme: _http, host: host, port: port, path: healthPath);
  Uri get kovaParams =>
      Uri(scheme: _http, host: host, port: port, path: kovaParamsPath);
  Uri get kovaParamsUpdate =>
      Uri(scheme: _http, host: host, port: port, path: kovaParamsUpdatePath);

  /// `/v1/git/<action>` (status, branches, log, plan, switch, reset, apply).
  Uri git(String action, [Map<String, String>? query]) => Uri(
    scheme: _http,
    host: host,
    port: port,
    path: '$gitPathPrefix$action',
    queryParameters: query,
  );

  /// The address alone on kovapilot's port, `address:port` otherwise.
  String get displayName {
    final shown = host.contains(':') ? '[$host]' : host;
    return port == kovaGatewayDefaultPort ? host : '$shown:$port';
  }

  @override
  bool operator ==(Object other) =>
      other is KovapilotEndpoints &&
      other.host == host &&
      other.port == port &&
      other.secure == secure;

  @override
  int get hashCode => Object.hash(host, port, secure);

  @override
  String toString() => 'KovapilotEndpoints($origin)';
}

/// What the user typed in "IP로 연결": `IP` or `IP:port` (port 8082 when
/// left out; IPv6 in brackets). Null with a Korean reason otherwise.
({String host, int port})? parseCommaAddress(
  String text, {
  void Function(String reason)? onError,
}) {
  final value = text.trim();
  ({String host, int port})? fail(String reason) {
    onError?.call(reason);
    return null;
  }

  if (value.isEmpty) return fail(CommaAddressText.empty);
  if (value.contains('/') || value.contains('@') || value.contains(' ')) {
    return fail(CommaAddressText.format);
  }
  String host;
  String? portText;
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close < 0) return fail(CommaAddressText.format);
    host = value.substring(1, close);
    final rest = value.substring(close + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return fail(CommaAddressText.format);
      portText = rest.substring(1);
    }
  } else if (':'.allMatches(value).length == 1) {
    final colon = value.indexOf(':');
    host = value.substring(0, colon);
    portText = value.substring(colon + 1);
  } else {
    host = value; // a name, IPv4, or bare IPv6 without a port
  }
  var port = kovaGatewayDefaultPort;
  if (portText != null) {
    final parsed = RegExp(r'^[0-9]{1,5}$').hasMatch(portText)
        ? int.parse(portText)
        : null;
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return fail(CommaAddressText.port);
    }
    port = parsed;
  }
  host = host.toLowerCase();
  final isIp = parseIPv4(host) != null || host.contains(':');
  if (!isIp && !host.endsWith('.local')) {
    return fail(CommaAddressText.format);
  }
  if (!isPolicyTarget(host, port)) return fail(CommaAddressText.notLocal);
  return (host: host, port: port);
}

abstract final class CommaAddressText {
  static const empty = '콤마의 IP를 넣어 주세요.';
  static const format = 'IP 모양이 아니에요. 예: 192.168.43.20';
  static const port = '포트는 1부터 65535 사이 숫자예요. 보통은 안 적어도 돼요.';
  static const notLocal = '같은 와이파이나 핫스팟 안의 IP만 쓸 수 있어요.';

  /// Where the comma shows its IP (openpilot UI: 설정 → 네트워크 → 고급 →
  /// IP 주소; comma four: the Wi-Fi item under 네트워크).
  static const whereToFind =
      '콤마 화면 왼쪽 위의 설정(톱니바퀴) → 네트워크 → 고급으로 가면 ‘IP 주소’가 보여요. '
      '작은 화면의 comma four는 설정 → 네트워크의 와이파이 칸에 IP가 함께 나와요.';
}
