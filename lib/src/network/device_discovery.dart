// Finding a kovapilot device (comma) on the phone's own Wi-Fi or hotspot
// network. Only addresses the local-only endpoint policy accepts are ever
// probed, and only on Wi-Fi, hotspot, USB or wired interfaces: mobile data
// (cellular) and VPN interfaces are never scanned.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_document.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

/// kovapilot gateway default port (`openpilot/kovapilot/gateway`).
const int kovaGatewayDefaultPort = 8082;

enum NetworkKind {
  wifi,
  hotspot,
  usb,
  ethernet,
  cellular,
  vpn,
  loopback,
  other,
}

extension NetworkKindLabel on NetworkKind {
  String get label => switch (this) {
    NetworkKind.wifi => '와이파이',
    NetworkKind.hotspot => '핫스팟',
    NetworkKind.usb => 'USB 연결',
    NetworkKind.ethernet => '유선',
    NetworkKind.cellular => '모바일 데이터',
    NetworkKind.vpn => 'VPN',
    NetworkKind.loopback => '이 기기',
    NetworkKind.other => '기타',
  };

  /// Kinds whose /24 may be scanned. Cellular, VPN, loopback and unknown
  /// interfaces are never scanned (a carrier network can hand out 10.x
  /// addresses that would pass the private-address check).
  bool get scannable => switch (this) {
    NetworkKind.wifi ||
    NetworkKind.hotspot ||
    NetworkKind.usb ||
    NetworkKind.ethernet => true,
    _ => false,
  };
}

/// Classifies an interface by its OS name (Android, iOS, Linux, macOS).
/// No permission is needed: names come from getifaddrs via dart:io.
NetworkKind classifyInterface(String name) {
  final n = name.toLowerCase();
  bool starts(List<String> prefixes) => prefixes.any(n.startsWith);
  if (n == 'lo' || starts(['lo0', 'loopback'])) return NetworkKind.loopback;
  if (starts([
    'rmnet',
    'r_rmnet',
    'rev_rmnet',
    'ccmni',
    'ccinet',
    'pdp_ip',
    'v4-',
    'clat',
    'wwan',
    'ppp',
    'seth',
    'qmi',
    'mhi',
    'cellular',
  ])) {
    return NetworkKind.cellular;
  }
  if (starts(['tun', 'utun', 'ipsec', 'tap', 'wg', 'tailscale', 'zt'])) {
    return NetworkKind.vpn;
  }
  if (starts([
    'docker',
    'veth',
    'br-',
    'virbr',
    'awdl',
    'llw',
    'anpi',
    'gif',
    'stf',
    'dummy',
    'p2p',
    'nan',
    'aware',
  ])) {
    return NetworkKind.other;
  }
  if (starts(['ap', 'swlan', 'softap', 'bridge', 'wifi_ap', 'wigig'])) {
    return NetworkKind.hotspot;
  }
  if (starts(['wlan', 'wl', 'wifi', 'en'])) return NetworkKind.wifi;
  if (starts(['rndis', 'usb', 'ncm', 'ecm'])) return NetworkKind.usb;
  if (starts(['eth'])) return NetworkKind.ethernet;
  return NetworkKind.other;
}

/// One IPv4 address of one local interface.
class LocalNetwork {
  const LocalNetwork({
    required this.interfaceName,
    required this.address,
    NetworkKind? kind,
  }) : kind = kind ?? NetworkKind.other;

  factory LocalNetwork.named(String interfaceName, String address) =>
      LocalNetwork(
        interfaceName: interfaceName,
        address: address,
        kind: classifyInterface(interfaceName),
      );

  final String interfaceName;
  final String address;
  final NetworkKind kind;

  /// True when this network's /24 may be scanned: an allowed interface kind
  /// and an address the local-only policy accepts.
  bool get scannable => kind.scannable && isPolicyAddress(address);

  /// `a.b.c.0/24`, or null for a non-IPv4 address.
  String? get subnetLabel {
    final octets = parseIPv4(address);
    if (octets == null) return null;
    return '${octets[0]}.${octets[1]}.${octets[2]}.0/24';
  }

  /// The same range as people write it on screen: `a.b.c.x`.
  String? get rangeLabel {
    final octets = parseIPv4(address);
    if (octets == null) return null;
    return '${octets[0]}.${octets[1]}.${octets[2]}.x';
  }

  String get signature => '$interfaceName=$address';

  @override
  bool operator ==(Object other) =>
      other is LocalNetwork &&
      other.interfaceName == interfaceName &&
      other.address == address &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(interfaceName, address, kind);

  @override
  String toString() => '$interfaceName $address (${kind.name})';
}

typedef NetworkLister = Future<List<LocalNetwork>> Function();

/// Real interface list (IPv4, no loopback). Cellular/VPN interfaces are
/// returned too so the connect screen can show them as "검색 안 함".
Future<List<LocalNetwork>> listLocalNetworks() async {
  final interfaces = await NetworkInterface.list(
    includeLoopback: false,
    includeLinkLocal: false,
    type: InternetAddressType.IPv4,
  );
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        if (address.type == InternetAddressType.IPv4)
          LocalNetwork.named(interface.name, address.address),
  ];
}

/// Canonical dotted-decimal IPv4, or null.
List<int>? parseIPv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final octets = <int>[];
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    octets.add(value);
  }
  return octets;
}

String _uriHost(String host) => host.contains(':') ? '[$host]' : host;

String _display(String host, int port) =>
    port == kovaGatewayDefaultPort ? host : '${_uriHost(host)}:$port';

/// True when `http://host:port` passes the local-only settings policy.
bool isPolicyTarget(String host, int port) =>
    LocalEndpointPolicy.validateSettings('http://${_uriHost(host)}:$port') ==
    null;

/// True when an IPv4 [address] passes the policy (private or loopback).
bool isPolicyAddress(String address) =>
    parseIPv4(address) != null &&
    isPolicyTarget(address, kovaGatewayDefaultPort);

/// All hosts of [network]'s /24 except the network/broadcast address and
/// the phone itself. Empty when the network may not be scanned.
List<String> subnetHosts(LocalNetwork network) {
  if (!network.scannable) return const [];
  final octets = parseIPv4(network.address)!;
  final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
  return [
    for (var i = 1; i <= 254; i++)
      if (i != octets[3]) '$prefix.$i',
  ];
}

bool _sameSubnet(String a, String b) {
  final x = parseIPv4(a);
  final y = parseIPv4(b);
  return x != null && y != null && x[0] == y[0] && x[1] == y[1] && x[2] == y[2];
}

enum CandidateSource { last, known, router, subnet }

class ProbeTarget {
  const ProbeTarget(this.host, this.port, this.source);
  final String host;
  final int port;
  final CandidateSource source;

  String get label => '${_uriHost(host)}:$port';
  String get key => '${host.toLowerCase()}:$port';

  /// On screen: the address alone on the usual port, address:port otherwise.
  String get displayName => _display(host, port);

  @override
  String toString() => '$label (${source.name})';
}

/// Ordered probe list for one search pass.
class DiscoveryPlan {
  const DiscoveryPlan({required this.priority, required this.scan});

  /// Last successful address, saved address and each network's `.1`
  /// router address, tried one by one first.
  final List<ProbeTarget> priority;

  /// The rest of every scannable /24, probed in parallel.
  final List<ProbeTarget> scan;

  bool get isEmpty => priority.isEmpty && scan.isEmpty;
  int get length => priority.length + scan.length;

  List<ProbeTarget> get all => [...priority, ...scan];

  /// Builds the plan. Every target passes [isPolicyTarget]; public hosts and
  /// cellular/VPN networks are left out. An IP address is tried only when it
  /// lies inside a scannable network (so nothing is sent over mobile data);
  /// `.local`/`localhost` names only when a scannable network exists.
  static DiscoveryPlan build({
    required List<LocalNetwork> networks,
    String? lastEndpoint,
    List<String> knownEndpoints = const [],
    List<int> ports = const [kovaGatewayDefaultPort],
    bool scanSubnets = true,
  }) {
    final scannable = networks.where((n) => n.scannable).toList();
    final own = {for (final n in networks) n.address};
    final seen = <String>{};
    final priority = <ProbeTarget>[];
    final scan = <ProbeTarget>[];
    final portList = ports.toSet().toList();

    bool reachable(String host) {
      if (LocalEndpointPolicy.isLoopbackHost(host)) return true;
      if (parseIPv4(host) != null) {
        return scannable.any((n) => _sameSubnet(n.address, host));
      }
      return scannable.isNotEmpty;
    }

    void add(List<ProbeTarget> into, ProbeTarget target) {
      if (!isPolicyTarget(target.host, target.port)) return;
      if (own.contains(target.host)) return;
      if (!reachable(target.host)) return;
      if (seen.add(target.key)) into.add(target);
    }

    ProbeTarget? fromEndpoint(String? endpoint, CandidateSource source) {
      if (endpoint == null ||
          LocalEndpointPolicy.validateSettings(endpoint) != null) {
        return null;
      }
      final uri = LocalEndpointPolicy.settingsBase(endpoint);
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      return ProbeTarget(uri.host, port, source);
    }

    if (fromEndpoint(lastEndpoint, CandidateSource.last) case final t?) {
      add(priority, t);
    }
    for (final endpoint in knownEndpoints) {
      if (fromEndpoint(endpoint, CandidateSource.known) case final t?) {
        add(priority, t);
      }
    }
    for (final network in scannable) {
      final octets = parseIPv4(network.address)!;
      for (final port in portList) {
        add(
          priority,
          ProbeTarget(
            '${octets[0]}.${octets[1]}.${octets[2]}.1',
            port,
            CandidateSource.router,
          ),
        );
      }
    }
    if (scanSubnets) {
      for (final network in scannable) {
        for (final host in subnetHosts(network)) {
          for (final port in portList) {
            add(scan, ProbeTarget(host, port, CandidateSource.subnet));
          }
        }
      }
    }
    return DiscoveryPlan(priority: priority, scan: scan);
  }
}

/// A kovapilot gateway that answered `/v1/health` correctly.
class KovaDevice {
  const KovaDevice({
    required this.host,
    required this.port,
    this.schemaVersion = supportedKovaParamsSchema,
    this.bindScope,
  });

  final String host;
  final int port;
  final int schemaVersion;
  final String? bindScope;

  String get label => '${_uriHost(host)}:$port';

  /// On screen: the address alone on the usual port, address:port otherwise.
  String get displayName => _display(host, port);

  /// Settings HTTP origin, e.g. `http://192.168.0.40:8082`.
  String get settingsEndpoint =>
      Uri(scheme: 'http', host: host, port: port).toString();

  @override
  bool operator ==(Object other) =>
      other is KovaDevice && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => 'KovaDevice($label)';
}

enum ProbeOutcome {
  /// Nothing listening, unreachable or timed out.
  noAnswer,

  /// Something answered but it is not a kovapilot gateway.
  notKova,

  /// `/v1/health` returned `status: ok` with schema major 1.
  kova,
}

class ProbeResult {
  const ProbeResult.noAnswer()
    : outcome = ProbeOutcome.noAnswer,
      device = null,
      detail = null;
  const ProbeResult.notKova(this.detail)
    : outcome = ProbeOutcome.notKova,
      device = null;
  const ProbeResult.kova(KovaDevice this.device)
    : outcome = ProbeOutcome.kova,
      detail = null;

  final ProbeOutcome outcome;
  final KovaDevice? device;
  final String? detail;
}

/// Checks one host:port. Tests replace it with a fake.
abstract class DeviceProbe {
  Future<ProbeResult> probe(String host, int port);
  void close();
}

/// Reads [body] as a kovapilot `/v1/health` answer. A plain open port or
/// another web server is not enough: the JSON must say `status: "ok"` and
/// carry a supported schema major.
ProbeResult judgeHealthResponse(
  String host,
  int port,
  int statusCode,
  String body,
) {
  if (statusCode != 200) return const ProbeResult.notKova(null);
  final Object? json;
  try {
    json = jsonDecode(body);
  } on FormatException {
    return const ProbeResult.notKova(null);
  }
  if (json is! Map || json['status'] != 'ok') {
    return const ProbeResult.notKova(null);
  }
  final major = kovaSchemaMajor(json['schemaVersion']);
  if (major != supportedKovaParamsSchema) {
    return const ProbeResult.notKova('kovapilot 버전이 앱과 맞지 않아요');
  }
  return ProbeResult.kova(
    KovaDevice(
      host: host,
      port: port,
      schemaVersion: major!,
      bindScope: json['bindScope'] is String
          ? json['bindScope'] as String
          : null,
    ),
  );
}

/// dart:io probe: `GET /v1/health` with short timeouts, no proxy, small
/// body cap. No SSH, no other port, nothing written to the device.
class HttpDeviceProbe implements DeviceProbe {
  HttpDeviceProbe({
    this.connectTimeout = const Duration(milliseconds: 450),
    this.responseTimeout = const Duration(milliseconds: 1500),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 2)
      ..maxConnectionsPerHost = 2
      ..findProxy = (_) => 'DIRECT';
  }

  static const maxBodyBytes = 8 * 1024;
  final Duration connectTimeout;
  final Duration responseTimeout;
  final HttpClient _client;

  @override
  Future<ProbeResult> probe(String host, int port) async {
    if (!isPolicyTarget(host, port)) return const ProbeResult.noAnswer();
    final uri = Uri(scheme: 'http', host: host, port: port, path: '/v1/health');
    HttpClientRequest? request;
    var connected = false;
    Future<ProbeResult> run() async {
      request = await _client.getUrl(uri);
      connected = true;
      request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request!.followRedirects = false;
      final response = await request!.close();
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
        if (chunks.length > maxBodyBytes) {
          return const ProbeResult.notKova(null);
        }
      }
      return judgeHealthResponse(
        host,
        port,
        response.statusCode,
        utf8.decode(chunks, allowMalformed: true),
      );
    }

    try {
      return await run().timeout(connectTimeout + responseTimeout);
    } on TimeoutException {
      request?.abort();
      return connected
          ? const ProbeResult.notKova('연결은 되는데 답이 없어요')
          : const ProbeResult.noAnswer();
    } on SocketException {
      return const ProbeResult.noAnswer();
    } on HandshakeException {
      return const ProbeResult.notKova(null);
    } on HttpException {
      return connected
          ? const ProbeResult.notKova(null)
          : const ProbeResult.noAnswer();
    } on Object {
      return const ProbeResult.noAnswer();
    }
  }

  @override
  void close() => _client.close(force: true);
}
