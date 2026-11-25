// One authenticated connection to one comma on Wi-Fi. Settings, Git,
// camera signaling and the telemetry WebSocket all go through
// [GatewaySession.client], so every request gets the same certificate check
// and the same token header.
//
// Certificate check: no system or bundled trust store is used
// (SecurityContext(withTrustedRoots: false)), and the decision is made on
// the certificate the comma itself presents (the leaf), after the TLS
// handshake and before the connection is handed to the HTTP client. Its
// public-key pin must equal the registered pin. A publicly trusted
// certificate is checked the same way. The token is added to a request only
// after that, so it is never sent to a comma whose pin does not match.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';

/// TCP connected but the TLS handshake never finished: something holds the
/// port without answering. A [SocketException] so every client treats it
/// as a transport failure; the Finder reads it as "found, no answer".
class GatewayHandshakeTimeout extends SocketException {
  const GatewayHandshakeTimeout() : super('TLS handshake timed out');
}

/// What the administrator gave the user for one comma.
@immutable
class GatewayCredentials {
  const GatewayCredentials({required this.pin, required this.token});

  final GatewayPin pin;

  /// 64 lowercase hex digits (kovapilot `token.sha256` is its SHA-256).
  final String token;

  static final _token = RegExp(r'^[0-9a-f]{64}$');

  /// The token as kovapilot accepts it (trimmed, lowercase), or null.
  static String? normalizeToken(String text) {
    final value = text.trim().toLowerCase();
    return _token.hasMatch(value) ? value : null;
  }

  @override
  String toString() => 'GatewayCredentials(${pin.short}, token hidden)';
}

/// Trust store used for Wi-Fi connections: empty on purpose.
SecurityContext gatewayTrustContext() =>
    SecurityContext(withTrustedRoots: false);

/// An HttpClient that opens TLS connections only to [host]:[port] and hands
/// a connection to HTTP only when [accept] approves the pin of the
/// certificate the server presented. [onPresented] sees every presented pin
/// (the Finder records it), [onConnected] fires once TCP is up. Proxies are
/// never used.
HttpClient gatewayTlsClient({
  String? host,
  int? port,
  required bool Function(GatewayPin? presented) accept,
  void Function(GatewayPin? presented)? onPresented,
  void Function()? onConnected,
  Duration connectTimeout = const Duration(seconds: 3),
  Duration handshakeTimeout = const Duration(seconds: 4),
  SecurityContext Function()? context,
}) {
  final trust = context ?? gatewayTrustContext;
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    // Never reached: every connection comes from the factory below. Kept
    // so a future code path without the factory fails closed.
    ..badCertificateCallback = ((_, _, _) => false);
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final secureScheme = uri.scheme == 'https' || uri.scheme == 'wss';
    if (!secureScheme ||
        proxyHost != null ||
        (host != null && uri.host.toLowerCase() != host.toLowerCase()) ||
        (port != null && uri.port != port)) {
      throw GatewayOriginRefused(uri);
    }
    final tcp = await Socket.startConnect(uri.host, uri.port);
    Future<Socket> secure() async {
      final plain = await tcp.socket.timeout(
        connectTimeout,
        onTimeout: () {
          tcp.cancel();
          throw const SocketException('connect timed out');
        },
      );
      onConnected?.call();
      final SecureSocket socket;
      try {
        socket =
            await SecureSocket.secure(
              plain,
              host: uri.host,
              context: trust(),
              // The handshake may finish whatever the chain is; the decision
              // is the pin check below, before any byte is written.
              onBadCertificate: (_) => true,
            ).timeout(
              handshakeTimeout,
              // Not a TimeoutException: HttpClient would take that for its own
              // connectionTimeout and drop the reason.
              onTimeout: () => throw const GatewayHandshakeTimeout(),
            );
      } on Object {
        plain.destroy();
        rethrow;
      }
      final presented = GatewayPin.ofCertificate(socket.peerCertificate);
      onPresented?.call(presented);
      if (!accept(presented)) {
        socket.destroy();
        throw GatewayIdentityMismatch(presented);
      }
      return socket;
    }

    return ConnectionTask.fromSocket(secure(), tcp.cancel);
  };
  return client;
}

class GatewaySession {
  GatewaySession._(
    this.endpoints,
    this.credentials,
    this.localNetworkPin,
    this.client,
  );

  /// Wi-Fi sessions check the pinned certificate with either bearer
  /// credentials or the certificate observed during local network discovery.
  factory GatewaySession({
    required KovapilotEndpoints endpoints,
    GatewayCredentials? credentials,
    GatewayPin? localNetworkPin,
    SecurityContext Function()? context,
    Duration connectTimeout = const Duration(seconds: 3),
  }) {
    if (!endpoints.secure) {
      final client = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionTimeout = connectTimeout;
      return GatewaySession._(endpoints, null, null, client);
    }
    final pin = credentials?.pin ?? localNetworkPin;
    if (pin == null || (credentials != null && localNetworkPin != null)) {
      throw ArgumentError('a Wi-Fi session needs exactly one access method');
    }
    late final GatewaySession session;
    final client = gatewayTlsClient(
      host: endpoints.host,
      port: endpoints.port,
      accept: pin.matches,
      onPresented: (presented) => session.lastPresented = presented,
      connectTimeout: connectTimeout,
      context: context,
    );
    session = GatewaySession._(endpoints, credentials, localNetworkPin, client);
    return session;
  }

  final KovapilotEndpoints endpoints;
  final GatewayCredentials? credentials;
  final GatewayPin? localNetworkPin;

  /// Tests: a session whose settings and Git requests go to [transport]
  /// (no network). Telemetry and camera are not used through it.
  @visibleForTesting
  GatewaySession.withTransport(
    KovaParamsTransport this._transport, {
    required this.endpoints,
    this.credentials,
    this.localNetworkPin,
  }) : client = HttpClient();

  /// The one client for every request to this comma.
  final HttpClient client;

  /// Pin of the certificate the comma presented on the last connection.
  GatewayPin? lastPresented;

  bool _closed = false;
  bool get isClosed => _closed;

  /// True when requests carry the token (Wi-Fi with a registered comma).
  bool get sendsToken => endpoints.secure && credentials != null;

  String? get wifiAuthentication => sendsToken
      ? 'bearer'
      : endpoints.secure && localNetworkPin != null
      ? 'localNetwork'
      : null;

  /// Headers for a WebSocket handshake. Never contains an Origin header
  /// (kovapilot refuses Wi-Fi requests that have one).
  Map<String, String> get authorization => sendsToken
      ? {HttpHeaders.authorizationHeader: 'Bearer ${credentials!.token}'}
      : const {};

  /// Adds the token to [request] and turns redirects off.
  void authorize(HttpClientRequest request) {
    request.followRedirects = false;
    if (!covers(request.uri)) throw GatewayOriginRefused(request.uri);
    if (sendsToken) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${credentials!.token}',
      );
    }
  }

  /// True when [uri] is this comma's origin (any path).
  bool covers(Uri uri) {
    final schemes = endpoints.secure
        ? const {'https', 'wss'}
        : const {'http', 'ws'};
    return schemes.contains(uri.scheme) &&
        uri.host.toLowerCase() == endpoints.host.toLowerCase() &&
        uri.port == endpoints.port;
  }

  /// How often the telemetry socket is pinged. A socket whose pong does not
  /// come back within this time is closed, so a comma that moved to another
  /// IP or left the hotspot is noticed (TCP alone can wait for minutes).
  static const telemetryPing = Duration(seconds: 5);

  /// Telemetry WebSocket through [client].
  Future<WebSocket> openWebSocket(String url) async {
    final uri = Uri.parse(url);
    if (!covers(uri)) throw GatewayOriginRefused(uri);
    final socket = await WebSocket.connect(
      url,
      headers: authorization,
      customClient: client,
    );
    if (endpoints.secure) socket.pingInterval = telemetryPing;
    return socket;
  }

  KovaParamsTransport? _transport;

  /// HTTP JSON transport for settings and Git through [client]. Closing it
  /// does not close the session.
  KovaParamsTransport get transport => _transport ??= IoKovaParamsTransport(
    client: client,
    decorate: authorize,
    ownsClient: false,
  );

  void close() {
    if (_closed) return;
    _closed = true;
    client.close(force: true);
  }

  @override
  String toString() =>
      'GatewaySession(${endpoints.origin}, token ${sendsToken ? 'on' : 'off'})';
}
