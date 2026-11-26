// A real TLS server on a loopback address that follows the kovapilot
// Wi-Fi Gateway rules (master-jh b476713a7, openpilot/kovapilot/gateway/
// app.py local_client): an Origin header or another Host gets 403
// wifi_client_required, a missing or wrong token 401 authentication_required
// with `WWW-Authenticate: Bearer`. Behind that, settings come from
// [FakeKovaGateway], telemetry sends one frame, /v1/stream answers an SDP,
// /v1/git/status a short status. Test certificates are in
// test/fixtures/gateway_tls (test use only).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/network/gateway_pin.dart';

import 'fake_kova_gateway.dart';

const tlsFixtures = 'test/fixtures/gateway_tls';

/// Pins computed with `openssl x509 -noout -pubkey | openssl pkey -pubin
/// -outform DER | sha256sum` (kovaPinCommand) on the fixture files.
const pinDeviceA =
    '298cab76d59d71aa36ec88cde90febcc911c39c7a00092905891ce9cfad8eff0';
const pinDeviceAB64 = 'KYyrdtWdcao27IjN6Q/rzJEcOcegAJKQWJHOnPrY7/A=';
const pinDeviceB =
    '24e38292285db24e4c2ee15fdbbda940d08e257185b8f163ed7fe59aa1649f7f';
const pinChainLeaf =
    '520d1032a2bf6c1f3d3fba4abdd57c36357f6d25c0876855f4143e62a87fa4cd';
const pinTestCa =
    'a9cae67abff9e53c72d8b955d7583104223ad2131994752877cd6d8b745e07f1';

const testToken =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

GatewayPin fixturePin(String hex) => GatewayPin.fromHex(hex)!;

String fixtureText(String name) =>
    File('$tlsFixtures/$name').readAsStringSync();

/// `device_a`, `device_b` (self-signed) or `chain` (leaf + test CA).
SecurityContext fixtureServerContext(String cert) {
  final key = cert == 'chain' ? 'chain_leaf' : cert;
  return SecurityContext()
    ..useCertificateChain('$tlsFixtures/$cert.pem')
    ..usePrivateKey('$tlsFixtures/$key.key');
}

class SeenRequest {
  SeenRequest(
    this.method,
    this.path,
    this.authorization,
    this.origin,
    this.host,
    this.upgrade,
  );
  final String method;
  final String path;
  final String? authorization;
  final String? origin;
  final String? host;
  final bool upgrade;

  @override
  String toString() => '$method $path auth=${authorization != null}';
}

class FakeWifiGateway {
  FakeWifiGateway._(this._server, this.address, this.token, this.localNetwork);

  static Future<FakeWifiGateway> start({
    String cert = 'device_a',
    String address = '127.0.0.2',
    String token = testToken,
    bool localNetwork = false,
    int port = 0,
  }) async {
    final server = await HttpServer.bindSecure(
      address,
      port,
      fixtureServerContext(cert),
    );
    final gateway = FakeWifiGateway._(server, address, token, localNetwork);
    server.listen(gateway._handle);
    return gateway;
  }

  final HttpServer _server;
  final String address;
  final bool localNetwork;
  String token;
  final settings = FakeKovaGateway();
  final requests = <SeenRequest>[];
  final sockets = <WebSocket>[];
  final streamBodies = <Map<String, dynamic>>[];

  /// Answer `/v1/health` with this schema version.
  int schemaVersion = 1;

  /// Never answer (accept and hold every request).
  bool silent = false;

  /// Automatic Wi-Fi owner (kovapilot master-jh owner pairing): the token
  /// the owner phone sends; null while nobody is registered.
  String? ownerToken;

  /// Code the comma "shows" and the token it hands out for it.
  String pairCode = '135790';
  String issuedToken = 'fe' * 32;

  /// Vehicle off (owner pairing needs it).
  bool offroad = true;

  /// Answer like a kovapilot without owner pairing (no owner fields).
  bool ownerPairingSupported = true;
  int pairRequests = 0;

  int get port => _server.port;
  String get origin => 'https://$address:$port';

  /// Requests that reached HTTP (after TLS).
  int get requestCount => requests.length;

  Future<void> _json(
    HttpRequest request,
    int status,
    Object body, [
    Map<String, String> headers = const {},
  ]) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    headers.forEach(request.response.headers.set);
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String code, [
    Map<String, String> headers = const {},
  ]) => _json(request, status, {
    'error': {'code': code, 'message': code},
  }, headers);

  Future<void> _handle(HttpRequest request) async {
    final upgrade = WebSocketTransformer.isUpgradeRequest(request);
    requests.add(
      SeenRequest(
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
        request.headers.value('origin'),
        request.headers.value(HttpHeaders.hostHeader),
        upgrade,
      ),
    );
    if (silent) return;
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (request.headers.value('origin') != null ||
        (host != address && host != '$address:$port')) {
      return _error(request, 403, 'wifi_client_required');
    }
    final auth = request.headers[HttpHeaders.authorizationHeader] ?? const [];
    if (!localNetwork && (auth.length != 1 || auth.single != 'Bearer $token')) {
      return _error(request, 401, 'authentication_required', {
        HttpHeaders.wwwAuthenticateHeader: 'Bearer',
      });
    }
    final owner =
        !localNetwork ||
        (ownerToken != null &&
            auth.length == 1 &&
            auth.single == 'Bearer $ownerToken');
    if (localNetwork && ownerPairingSupported && auth.isNotEmpty && !owner) {
      return _error(request, 401, 'authentication_required', {
        HttpHeaders.wwwAuthenticateHeader: 'Bearer',
      });
    }
    switch ((request.method, request.uri.path)) {
      case ('GET', '/v1/health'):
        return _json(request, 200, {
          'status': 'ok',
          'schemaVersion': schemaVersion,
          'bindScope': 'wifi',
          'authentication': localNetwork ? 'localNetwork' : 'bearer',
          if (ownerPairingSupported) ...{
            'owner': owner,
            'ownerRegistered': !localNetwork || ownerToken != null,
            'ownerPairing': localNetwork,
          },
        });
      case ('POST', '/v1/owner/pair')
          when localNetwork && ownerPairingSupported:
        await utf8.decodeStream(request);
        if (!offroad) return _error(request, 409, 'owner_pairing_offroad');
        pairRequests++;
        return _json(request, 200, {'expiresIn': 120});
      case ('POST', '/v1/owner/confirm')
          when localNetwork && ownerPairingSupported:
        final body = jsonDecode(await utf8.decodeStream(request));
        if (body is Map && body['code'] == pairCode) {
          ownerToken = issuedToken;
          return _json(request, 200, {'token': issuedToken});
        }
        return _json(request, 403, {
          'error': {
            'code': 'owner_pairing_code_invalid',
            'message': 'the code does not match',
            'remainingAttempts': 4,
          },
        });
      case ('GET', '/v1/vpn'):
        if (!owner) return _error(request, 403, 'forbidden');
        return _json(request, 200, {'state': 'needsLogin'});
      case ('GET', '/v1/kova-params'):
        final r = await settings.get(request.uri, const Duration(seconds: 5));
        request.response.statusCode = r.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(r.body);
        return request.response.close();
      case ('POST', '/v1/kova-params/update'):
        final body = await utf8.decodeStream(request);
        final r = await settings.postJson(
          request.uri,
          body,
          const Duration(seconds: 5),
        );
        request.response.statusCode = r.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(r.body);
        return request.response.close();
      case ('GET', '/v1/telemetry') when upgrade:
        final ws = await WebSocketTransformer.upgrade(request);
        sockets.add(ws);
        ws.add(jsonEncode({'schemaVersion': 1, 'speedMps': 7.5}));
        ws.listen((_) {}, onDone: () {});
        return;
      case ('POST', '/v1/stream'):
        final body = jsonDecode(await utf8.decodeStream(request));
        streamBodies.add(body as Map<String, dynamic>);
        return _json(request, 200, {'sdp': 'v=0 answer', 'type': 'answer'});
      case ('GET', '/v1/git/status'):
        return _json(request, 200, {
          'branch': 'master-jh',
          'head': 'b476713a7406217a5c10ce8ec361f095eb4dc4be',
          'upstream': 'origin/master-jh',
          'dirty': false,
          'updaterState': 'idle',
        });
      default:
        return _error(request, 404, 'not_found');
    }
  }

  Future<void> close() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}
