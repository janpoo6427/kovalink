import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/services/comma_link.dart';

enum VpnAction { status, connect, stop, disconnect }

class TailscaleVpnClient {
  const TailscaleVpnClient(this.link);

  final CommaLink link;
  static const _timeout = Duration(seconds: 8);
  static final _loginUrl = RegExp(
    r'^https://login\.tailscale\.com/a/[A-Za-z0-9_-]{1,128}$',
  );

  bool get canManage {
    final session = link.session;
    return session != null &&
        !session.isClosed &&
        session.sendsToken &&
        session.credentials?.pin == link.registered?.pin;
  }

  static Uri? loginUri(Object? value) =>
      value is String && _loginUrl.hasMatch(value) ? Uri.parse(value) : null;

  static String readToken(String ownerToken) => Hmac(
    sha256,
    sha256.convert(ascii.encode(ownerToken)).bytes,
  ).convert(ascii.encode('kovalink-tailscale-read-v1')).toString();

  Future<Map<String, dynamic>> manage(VpnAction action) async {
    final session = link.session;
    final registered = link.registered;
    if (!canManage || session == null || registered == null) {
      throw const VpnException('같은 Wi-Fi에서 소유자 연결을 먼저 확인해 주세요.');
    }
    final base = session.endpoints.origin;
    final transport = session.transport;
    final response = switch (action) {
      VpnAction.status => await transport.get(
        Uri.parse('$base/v1/vpn'),
        _timeout,
      ),
      _ => await transport.postJson(
        Uri.parse('$base/v1/vpn/${action.name}'),
        '{}',
        _timeout,
      ),
    };
    final status = _decode(response);
    if (link.session != session ||
        session.isClosed ||
        link.registered?.pin != registered.pin) {
      throw const VpnException('연결된 콤마가 바뀌었어요.');
    }
    final host = status['host'];
    if (action == VpnAction.disconnect ||
        status['state'] == 'connected' &&
            host is String &&
            RegisteredComma.isTailscaleHost(host)) {
      final nextHost = action == VpnAction.disconnect ? null : host as String;
      if (link.registered?.vpnHost != nextHost) {
        await link.settings.update((settings) {
          final current = settings.registeredComma;
          return current?.pin == registered.pin && current != null
              ? settings.copyWith(
                  registeredComma: current.withVpnHost(nextHost),
                )
              : settings;
        });
      }
    }
    return status;
  }

  Future<Map<String, dynamic>> snapshot() async {
    final registered = link.registered;
    final host = registered?.vpnHost;
    if (registered == null ||
        host == null ||
        !RegisteredComma.isTailscaleHost(host)) {
      throw const VpnException('같은 Wi-Fi에서 VPN 등록을 먼저 완료해 주세요.');
    }
    final token = await link.tokens.read(registered.pin);
    if (token == null || link.registered != registered) {
      throw const VpnException('콤마의 소유자 등록을 확인해 주세요.');
    }
    final vpnToken = readToken(token);
    final transport = IoKovaParamsTransport(
      decorate: (request) {
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $vpnToken',
        );
      },
    );
    try {
      return _decode(
        await transport.get(Uri.https(host, '/v1/vpn/device'), _timeout),
      );
    } finally {
      transport.close();
    }
  }

  static Map<String, dynamic> _decode(KovaHttpResponse response) {
    if (response.statusCode != 200) {
      throw VpnException(switch (response.statusCode) {
        403 => '이 장치의 소유자 연결을 확인해 주세요.',
        404 => '이 콤마의 Gateway에서는 VPN 기능을 사용할 수 없어요.',
        409 => 'P단에 세우거나 시동을 끈 상태에서 VPN을 등록하거나 해제해 주세요.',
        503 => '콤마의 Tailscale 서비스가 아직 준비되지 않았어요.',
        _ => '콤마의 VPN 응답을 확인할 수 없어요.',
      });
    }
    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw const VpnException('콤마의 VPN 응답 형식이 올바르지 않아요.');
    }
    return json;
  }
}

class VpnException implements Exception {
  const VpnException(this.message);
  final String message;
}
