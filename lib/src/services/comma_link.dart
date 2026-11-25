// The registered comma, its token and the one open session to it. Shared by
// auto-connect, the connection screen, the kovapilot settings tab, the
// camera and Git, so they all use the same pinned client and token.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/settings/app_settings.dart';

typedef GatewaySessionFactory =
    GatewaySession Function(
      KovapilotEndpoints endpoints,
      GatewayCredentials? credentials,
    );

GatewaySession _defaultSession(
  KovapilotEndpoints endpoints,
  GatewayCredentials? credentials,
) => GatewaySession(endpoints: endpoints, credentials: credentials);

/// Result of an authenticated `/v1/health` through a session.
typedef GatewayCheck = ({KovaLinkProblem? problem, KovaGatewayHealth? health});

class CommaLink extends ChangeNotifier {
  CommaLink({
    required this.settings,
    required this.tokens,
    GatewaySessionFactory? sessionFactory,
    this.timeout = const Duration(seconds: 5),
  }) : _sessionFactory = sessionFactory ?? _defaultSession;

  final SettingsController settings;
  final CommaTokenStore tokens;
  final GatewaySessionFactory _sessionFactory;
  final Duration timeout;

  GatewaySession? _session;
  bool _disposed = false;

  /// The open session (null until a comma is connected).
  GatewaySession? get session => _session;

  /// Last `/v1/health` the comma answered through [session].
  KovaGatewayHealth? health;

  /// Why the last [open] or [register] failed; null when fine.
  KovaLinkProblem? problem;

  RegisteredComma? get registered => settings.value.registeredComma;

  /// True when [device] may be connected without the user: the registered
  /// comma (same pin, any address) or a loopback development gateway.
  bool canAttach(KovaDevice device) =>
      !device.secure || (registered?.isPresentedBy(device) ?? false);

  /// The session for the comma at [address] (any path on its origin).
  GatewaySession? sessionFor(String address) {
    final session = _session;
    if (session == null || session.isClosed) return null;
    final uri = Uri.tryParse(address);
    return uri != null && session.covers(uri) ? session : null;
  }

  /// Opens the session to [device] and checks it (pin, then token). Null
  /// when it is ready; the problem otherwise. A working session to the same
  /// address is kept.
  Future<KovaLinkProblem?> open(KovaDevice device) async {
    final endpoints = KovapilotEndpoints(
      host: device.host,
      port: device.port,
      secure: device.secure,
    );
    final current = _session;
    if (current != null &&
        !current.isClosed &&
        current.endpoints == endpoints) {
      if (!device.secure || current.credentials?.pin == registered?.pin) {
        return _ok(current, health);
      }
    }
    if (!device.secure) {
      // A loopback development gateway: plain HTTP without a token, opened
      // directly as before (no session).
      _replace(null);
      health = null;
      problem = null;
      _notify();
      return null;
    }
    final comma = registered;
    if (comma == null || !comma.isPresentedBy(device)) {
      return _fail(KovaLinkProblem.needsRegistration);
    }
    final token = await tokens.read(comma.pin);
    if (token == null) return _fail(KovaLinkProblem.needsToken);
    final candidate = _sessionFactory(
      endpoints,
      GatewayCredentials(pin: comma.pin, token: token),
    );
    final result = await check(candidate);
    if (result.problem case final problem?) {
      candidate.close();
      return _fail(problem);
    }
    if (comma.host != device.host || comma.port != device.port) {
      unawaited(
        settings.update(
          (s) =>
              s.copyWith(registeredComma: comma.at(device.host, device.port)),
        ),
      );
    }
    return _ok(candidate, result.health);
  }

  /// Authenticated `/v1/health` through [session]. Stores nothing.
  Future<GatewayCheck> check(GatewaySession session) async {
    final client = KovaParamsClient(
      Uri.parse(session.endpoints.origin),
      transport: session.transport,
      timeout: timeout,
    );
    try {
      final health = await client.health();
      if (session.endpoints.secure &&
          (health.bindScope != 'wifi' || health.authentication != 'bearer')) {
        return (problem: KovaLinkProblem.notKova, health: health);
      }
      return (problem: null, health: health);
    } on KovaParamsException catch (error) {
      return (problem: problemOf(error.kind), health: null);
    }
  }

  static KovaLinkProblem problemOf(KovaFailureKind kind) => switch (kind) {
    KovaFailureKind.unauthorized => KovaLinkProblem.tokenRejected,
    KovaFailureKind.identity => KovaLinkProblem.identityMismatch,
    KovaFailureKind.notAllowed => KovaLinkProblem.notAllowed,
    KovaFailureKind.schema => KovaLinkProblem.versionMismatch,
    KovaFailureKind.timeout ||
    KovaFailureKind.transport => KovaLinkProblem.noAnswer,
    KovaFailureKind.http || KovaFailureKind.format => KovaLinkProblem.notKova,
  };

  /// Registers the comma at [host]:[port] with [pin] and [token] once the
  /// comma answered with that certificate and accepted that token. Nothing
  /// is saved otherwise. Replaces an earlier registration.
  Future<KovaLinkProblem?> register({
    required String host,
    required int port,
    required GatewayPin pin,
    required String token,
  }) async {
    final candidate = _sessionFactory(
      KovapilotEndpoints(host: host, port: port, secure: true),
      GatewayCredentials(pin: pin, token: token),
    );
    final result = await check(candidate);
    if (result.problem case final problem?) {
      candidate.close();
      return problem;
    }
    final previous = registered;
    if (previous != null && previous.pin != pin) {
      await tokens.delete(previous.pin);
    }
    await tokens.write(pin, token);
    // In memory at once; the settings file follows like every other change.
    unawaited(
      settings.update(
        (s) => s.copyWith(
          registeredComma: RegisteredComma(pin: pin, host: host, port: port),
        ),
      ),
    );
    return _ok(candidate, result.health);
  }

  /// Removes the registration and its token, and closes the session.
  Future<void> forget() async {
    final comma = registered;
    if (comma != null) await tokens.delete(comma.pin);
    await settings.update((s) => s.copyWith(clearRegisteredComma: true));
    _replace(null);
    health = null;
    problem = null;
    _notify();
  }

  KovaLinkProblem? _ok(GatewaySession session, KovaGatewayHealth? health) {
    _replace(session);
    this.health = health;
    problem = null;
    _notify();
    return null;
  }

  KovaLinkProblem _fail(KovaLinkProblem problem) {
    this.problem = problem;
    _notify();
    return problem;
  }

  void _replace(GatewaySession? next) {
    final previous = _session;
    _session = next;
    if (previous != null && !identical(previous, next)) previous.close();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _replace(null);
    super.dispose();
  }
}
