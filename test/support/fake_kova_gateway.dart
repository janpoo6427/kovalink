// In-memory kovapilot gateway for tests and captures. It follows the
// gateway's documented contract (docs/PROTOCOL.md "Settings HTTP"): exact
// update fields, unknown key / type / range -> 400 invalid_value, read-only
// or offroad policy -> 403 update_forbidden, stale revision -> 409.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_client.dart';

Map<String, dynamic> loadKovaCatalogFixture() =>
    jsonDecode(
          File('test/fixtures/kova_params_catalog.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

enum FakePostMode { normal, timeout, timeoutButApplied, fail }

class FakeKovaGateway implements KovaParamsTransport {
  FakeKovaGateway({Map<String, dynamic>? catalog, this.offroad = true})
    : catalog = catalog ?? loadKovaCatalogFixture();

  final Map<String, dynamic> catalog;
  bool offroad;
  bool parked = false;
  bool reportOffroad = true;
  bool down = false;
  int revision = 0;
  final Map<String, Object?> values = {};
  final List<Map<String, dynamic>> posts = [];
  int gets = 0;
  FakePostMode nextPost = FakePostMode.normal;

  /// When set, POST waits for it (to capture the "보내는 중" state).
  Completer<void>? hold;

  /// Extra top-level fields merged into the document (format tests).
  Map<String, Object?> extra = {};

  List<Map<String, dynamic>> get _settings =>
      (catalog['settings'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic>? _setting(String key) {
    for (final s in _settings) {
      if (s['key'] == key) return s;
    }
    return null;
  }

  Object? valueOf(String key) =>
      values.containsKey(key) ? values[key] : _setting(key)?['defaultValue'];

  Map<String, dynamic> document() {
    final doc = jsonDecode(jsonEncode(catalog)) as Map<String, dynamic>;
    doc['revision'] = revision;
    for (final s in (doc['settings'] as List).cast<Map<String, dynamic>>()) {
      s['value'] = valueOf(s['key'] as String);
      s['applyStatus'] = s['availability'];
    }
    if (reportOffroad) doc['device'] = {'offroad': offroad, 'parked': parked};
    doc.addAll(extra);
    return doc;
  }

  /// Another writer (e.g. the comma screen) changes a value.
  void externalWrite(String key, Object? value) {
    values[key] = value;
    revision++;
  }

  static KovaHttpResponse _json(int status, Object body) =>
      KovaHttpResponse(status, jsonEncode(body));

  static KovaHttpResponse _error(int status, String code, String message) =>
      _json(status, {
        'error': {'code': code, 'message': message},
      });

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async {
    if (down) throw const SocketException('connection refused');
    gets++;
    return switch (uri.path) {
      '/v1/health' => _json(200, {
        'status': 'ok',
        'schemaVersion': 1,
        'bindScope': 'loopback',
        'authentication': 'localProcessOnly',
      }),
      '/v1/kova-params' => _json(200, document()),
      _ => const KovaHttpResponse(404, '404: Not Found'),
    };
  }

  bool _typeOk(Map<String, dynamic> s, Object? v) => switch (s['type']) {
    'boolean' => v is bool,
    'integer' => v is int,
    'number' => v is num && v.isFinite,
    'string' => v is String,
    'enum' => (s['options'] as List).any(
      (o) => ((o is int && v is int) || (o is String && v is String)) && o == v,
    ),
    _ => false,
  };

  KovaHttpResponse _apply(Map<String, dynamic> body) {
    final nativeLongitudinal = body['key'] == 'cruise.openpilot_longitudinal';
    final fields = {
      'key',
      'value',
      'expectedRevision',
      if (nativeLongitudinal) 'expectedValue',
    };
    if (body.keys.toSet().difference(fields).isNotEmpty ||
        body.length != fields.length) {
      return _error(
        400,
        'invalid_request',
        'request fields must be key, value, and expectedRevision',
      );
    }
    final key = body['key'] as String;
    final value = body['value'];
    final s = _setting(key);
    if (s == null) return _error(400, 'invalid_value', 'unknown setting: $key');
    if (nativeLongitudinal &&
        body['expectedValue'] != (values[key] ?? s['defaultValue'])) {
      return _error(
        409,
        'revision_conflict',
        'longitudinal preference changed',
      );
    }
    if (s['access'] != 'readWrite') {
      return _error(403, 'update_forbidden', 'setting is read-only: $key');
    }
    if (s['applyPolicy'] == 'offroad' && !offroad) {
      return _error(
        403,
        'update_forbidden',
        'setting can only be changed offroad: $key',
      );
    }
    if (s['applyPolicy'] == 'parked' && !offroad && !parked) {
      return _error(
        403,
        'update_forbidden',
        'setting can only be changed when parked or offroad: $key',
      );
    }
    if (!_typeOk(s, value)) {
      return _error(
        400,
        'invalid_value',
        'invalid value for $key: expected ${s['type']}',
      );
    }
    if (value is num &&
        ((s['minimum'] is num && value < (s['minimum'] as num)) ||
            (s['maximum'] is num && value > (s['maximum'] as num)))) {
      return _error(400, 'invalid_value', 'value out of range for $key');
    }
    if (body['expectedRevision'] != revision) {
      return _error(
        409,
        'revision_conflict',
        'revision conflict: expected ${body['expectedRevision']}, current $revision',
      );
    }
    values[key] = value;
    revision++;
    return _json(200, document());
  }

  @override
  Future<KovaHttpResponse> postJson(
    Uri uri,
    String body,
    Duration timeout,
  ) async {
    if (down) throw const SocketException('connection refused');
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    posts.add(decoded);
    if (hold case final gate?) await gate.future;
    final mode = nextPost;
    nextPost = FakePostMode.normal;
    switch (mode) {
      case FakePostMode.timeout:
        throw TimeoutException('fake timeout');
      case FakePostMode.timeoutButApplied:
        _apply(decoded);
        throw TimeoutException('fake timeout after apply');
      case FakePostMode.fail:
        throw const SocketException('connection reset');
      case FakePostMode.normal:
        return _apply(decoded);
    }
  }

  @override
  void close() {}
}
