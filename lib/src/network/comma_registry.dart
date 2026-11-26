// The comma registered on this phone. Its pin, last address and port are
// app settings (not secret); its token lives only in the phone's secure
// storage (Android Keystore / iOS Keychain) and is never written to the
// settings file, logs or the screen.
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

@immutable
class RegisteredComma {
  const RegisteredComma({
    required this.pin,
    required this.host,
    this.port = kovaGatewayDefaultPort,
    this.vpnHost,
  });

  /// The comma's identity. Its address may change; the pin does not.
  final GatewayPin pin;

  /// Last address it answered on (tried first by the Finder).
  final String host;
  final int port;
  final String? vpnHost;

  /// The comma's VPN IP (no MagicDNS name).
  static bool isTailscaleHost(String host) =>
      LocalEndpointPolicy.isTailnetAddress(host);

  /// The Gateway over the comma's VPN, when its VPN IP is known.
  String? get vpnEndpoint => vpnHost == null
      ? null
      : KovapilotEndpoints(
          host: vpnHost!,
          port: kovaGatewayTailnetPort,
          secure: true,
        ).origin;

  KovapilotEndpoints get endpoints =>
      KovapilotEndpoints(host: host, port: port, secure: true);

  /// Same comma, new address.
  RegisteredComma at(String host, int port) =>
      RegisteredComma(pin: pin, host: host, port: port, vpnHost: vpnHost);

  RegisteredComma withVpnHost(String? value) =>
      RegisteredComma(pin: pin, host: host, port: port, vpnHost: value);

  /// True when [device] presented this comma's certificate over TLS.
  bool isPresentedBy(KovaDevice device) =>
      device.secure && pin.matches(device.pin);

  Map<String, Object> toJson() => {
    'pin': pin.hex,
    'host': host,
    'port': port,
    'vpnHost': ?vpnHost,
  };

  /// Null unless the pin, host (local-only policy) and port are valid.
  static RegisteredComma? fromJson(Object? json) {
    if (json is! Map) return null;
    final pin = GatewayPin.fromHex(json['pin'] is String ? json['pin'] : null);
    final host = json['host'];
    final port = json['port'];
    if (pin == null || host is! String || port is! int) return null;
    if (port < 1 || port > 65535 || !isPolicyTarget(host, port)) return null;
    final vpnHost = json['vpnHost'];
    return RegisteredComma(
      pin: pin,
      host: host,
      port: port,
      vpnHost: vpnHost is String && isTailscaleHost(vpnHost) ? vpnHost : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RegisteredComma &&
      other.pin == pin &&
      other.host == host &&
      other.port == port &&
      other.vpnHost == vpnHost;

  @override
  int get hashCode => Object.hash(pin, host, port, vpnHost);

  @override
  String toString() => 'RegisteredComma(${pin.short} at $host:$port)';
}

/// Where tokens are kept, by comma pin. Tests use [MemoryCommaTokenStore].
abstract class CommaTokenStore {
  Future<String?> read(GatewayPin pin);
  Future<void> write(GatewayPin pin, String token);
  Future<void> delete(GatewayPin pin);
}

/// flutter_secure_storage: Android Keystore-wrapped keys, iOS Keychain
/// (this device only, after first unlock; never synced to iCloud).
class SecureCommaTokenStore implements CommaTokenStore {
  SecureCommaTokenStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _storage;

  static String keyFor(GatewayPin pin) => 'kovalink.comma.token.${pin.hex}';

  @override
  Future<String?> read(GatewayPin pin) async {
    try {
      return await _storage.read(key: keyFor(pin));
    } on Object {
      // A backup restored on another phone cannot be decrypted: treat it
      // as no token (the app asks to register again).
      return null;
    }
  }

  @override
  Future<void> write(GatewayPin pin, String token) =>
      _storage.write(key: keyFor(pin), value: token);

  @override
  Future<void> delete(GatewayPin pin) => _storage.delete(key: keyFor(pin));
}

class MemoryCommaTokenStore implements CommaTokenStore {
  final Map<String, String> tokens = {};
  int reads = 0;

  @override
  Future<String?> read(GatewayPin pin) async {
    reads++;
    return tokens[pin.hex];
  }

  @override
  Future<void> write(GatewayPin pin, String token) async =>
      tokens[pin.hex] = token;

  @override
  Future<void> delete(GatewayPin pin) async => tokens.remove(pin.hex);
}
