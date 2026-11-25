// HTTP client for the kovapilot gateway settings API (docs/PROTOCOL.md,
// "Settings HTTP"). No request is ever treated as successful unless the
// gateway answered 200 with an authoritative document.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_document.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

class KovaHttpResponse {
  const KovaHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// Raw HTTP seam so tests can replace the network.
abstract class KovaParamsTransport {
  Future<KovaHttpResponse> get(Uri uri, Duration timeout);
  Future<KovaHttpResponse> postJson(Uri uri, String body, Duration timeout);
  void close();
}

/// dart:io transport. Bodies over [maxBodyBytes] are refused; a timed-out
/// request is aborted. A comma on Wi-Fi passes its session's client, which
/// checks the certificate pin, and [decorate] adds the token; [ownsClient]
/// false leaves that shared client open on [close].
class IoKovaParamsTransport implements KovaParamsTransport {
  IoKovaParamsTransport({
    HttpClient? client,
    this.decorate,
    this.ownsClient = true,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 3);
    // Never use a system proxy for a local device.
    _client.findProxy = (_) => 'DIRECT';
  }

  static const maxBodyBytes = 1024 * 1024;
  final HttpClient _client;

  /// Called on every request before anything is sent (token header).
  final void Function(HttpClientRequest request)? decorate;
  final bool ownsClient;

  Future<KovaHttpResponse> _send(
    Future<HttpClientRequest> Function() open,
    Duration timeout, [
    String? body,
  ]) async {
    HttpClientRequest? request;
    Future<KovaHttpResponse> run() async {
      request = await open();
      request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
      decorate?.call(request!);
      if (body != null) {
        final bytes = utf8.encode(body);
        request!.headers.contentType = ContentType.json;
        request!.contentLength = bytes.length;
        request!.add(bytes);
      }
      final response = await request!.close();
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
        if (chunks.length > maxBodyBytes) {
          throw const HttpException('gateway 응답이 너무 큽니다.');
        }
      }
      return KovaHttpResponse(
        response.statusCode,
        utf8.decode(chunks, allowMalformed: false),
      );
    }

    try {
      return await run().timeout(timeout);
    } on TimeoutException {
      request?.abort();
      rethrow;
    }
  }

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) =>
      _send(() => _client.getUrl(uri), timeout);

  @override
  Future<KovaHttpResponse> postJson(Uri uri, String body, Duration timeout) =>
      _send(() => _client.postUrl(uri), timeout, body);

  @override
  void close() {
    if (ownsClient) _client.close(force: true);
  }
}

enum KovaFailureKind {
  timeout,
  transport,
  http,
  format,
  schema,

  /// 401: the token was refused.
  unauthorized,

  /// 403 `wifi_client_required` / `local_client_required`.
  notAllowed,

  /// The certificate pin is not the registered comma's; nothing was sent.
  identity,
}

class KovaParamsException implements Exception {
  const KovaParamsException(this.kind, this.message, {this.statusCode});
  final KovaFailureKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class KovaGatewayHealth {
  const KovaGatewayHealth({
    required this.status,
    required this.schemaVersion,
    this.bindScope,
    this.authentication,
  });
  final String status;
  final int schemaVersion;
  final String? bindScope;
  final String? authentication;
}

sealed class KovaUpdateOutcome {
  const KovaUpdateOutcome();
}

/// 200: the gateway stored the value and returned the new document.
class KovaUpdateApplied extends KovaUpdateOutcome {
  const KovaUpdateApplied(this.document);
  final KovaParamsDocument document;
}

/// 409 revision_conflict: someone changed the document first.
class KovaUpdateConflict extends KovaUpdateOutcome {
  const KovaUpdateConflict();
}

/// 4xx/5xx with an error code; nothing was stored.
class KovaUpdateRejected extends KovaUpdateOutcome {
  const KovaUpdateRejected({
    required this.code,
    required this.statusCode,
    required this.reason,
  });
  final String code;
  final int statusCode;

  /// Korean, user-facing; never the raw gateway message.
  final String reason;
}

/// No answer in time. The value may or may not have been stored.
class KovaUpdateTimedOut extends KovaUpdateOutcome {
  const KovaUpdateTimedOut();
}

/// Transport/format failure. The value may or may not have been stored.
class KovaUpdateFailed extends KovaUpdateOutcome {
  const KovaUpdateFailed(this.message);
  final String message;
}

/// Maps a gateway error to a short Korean reason without echoing details.
String kovaRejectionReason(String code, String message) {
  final lower = message.toLowerCase();
  return switch (code) {
    'update_forbidden' when lower.contains('offroad') =>
      '주행 중에는 바꿀 수 없어요. 차를 세운 뒤 다시 해 주세요.',
    'update_forbidden' when lower.contains('read-only') =>
      '읽기 전용 항목이라 바꿀 수 없어요.',
    'update_forbidden' => '차에서 이 변경을 막았어요.',
    'invalid_value' when lower.contains('unknown setting') =>
      '차가 모르는 항목이에요. 새로고침해 주세요.',
    'invalid_value' when lower.contains('out of range') =>
      '차에서 쓸 수 있는 범위를 벗어났어요.',
    'invalid_value' => '차에서 받을 수 없는 값이에요.',
    'invalid_request' || 'invalid_json' => '차가 요청을 읽지 못했어요. 앱을 업데이트해 주세요.',
    'kova_params_unavailable' => '차에서 설정을 불러올 수 없어요. 잠시 뒤 다시 해 주세요.',
    'local_client_required' => '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.',
    'authentication_required' => KovaLinkText.message(
      KovaLinkProblem.tokenRejected,
    ),
    'wifi_client_required' => KovaLinkText.message(KovaLinkProblem.notAllowed),
    _ => '차에서 변경을 막았어요.',
  };
}

class KovaParamsClient {
  KovaParamsClient(
    this.baseUri, {
    KovaParamsTransport? transport,
    this.timeout = const Duration(seconds: 5),
  }) : transport = transport ?? IoKovaParamsTransport();

  /// Validates [endpoint] with the local-only policy first.
  static KovaParamsClient? tryCreate(
    String endpoint, {
    KovaParamsTransport? transport,
    Duration timeout = const Duration(seconds: 5),
    void Function(String error)? onError,
  }) {
    final error = LocalEndpointPolicy.validateSettings(endpoint);
    if (error != null) {
      onError?.call(error);
      return null;
    }
    return KovaParamsClient(
      LocalEndpointPolicy.settingsBase(endpoint),
      transport: transport,
      timeout: timeout,
    );
  }

  final Uri baseUri;
  final KovaParamsTransport transport;
  final Duration timeout;

  Uri _uri(String path) => baseUri.replace(path: path);

  Future<KovaHttpResponse> _guard(
    Future<KovaHttpResponse> Function() call,
  ) async {
    try {
      return await call();
    } on TimeoutException {
      throw const KovaParamsException(
        KovaFailureKind.timeout,
        '차에서 응답이 없어요. 잠시 뒤 다시 해 주세요.',
      );
    } on FormatException {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '차에서 받은 내용을 읽을 수 없어요.',
      );
    } on GatewayIdentityMismatch {
      throw KovaParamsException(
        KovaFailureKind.identity,
        KovaLinkText.message(KovaLinkProblem.identityMismatch),
      );
    } on GatewayOriginRefused {
      throw const KovaParamsException(
        KovaFailureKind.transport,
        '차에 연결할 수 없어요. 같은 네트워크에 있는지 확인해 주세요.',
      );
    } on IOException {
      throw const KovaParamsException(
        KovaFailureKind.transport,
        '차에 연결할 수 없어요. 같은 네트워크에 있는지 확인해 주세요.',
      );
    }
  }

  /// 401 and 403 answers from a comma on Wi-Fi, or null for others.
  static KovaParamsException? _accessError(KovaHttpResponse response) {
    if (response.statusCode == 401) {
      return KovaParamsException(
        KovaFailureKind.unauthorized,
        KovaLinkText.message(KovaLinkProblem.tokenRejected),
        statusCode: 401,
      );
    }
    if (response.statusCode == 403) {
      Object? json;
      try {
        json = jsonDecode(response.body);
      } on FormatException {
        json = null;
      }
      final code = _error(json)?.$1;
      // local_client_required (a loopback-only gateway) keeps its own
      // message: see kovaRejectionReason.
      if (code == 'wifi_client_required') {
        return KovaParamsException(
          KovaFailureKind.notAllowed,
          KovaLinkText.message(KovaLinkProblem.notAllowed),
          statusCode: 403,
        );
      }
    }
    return null;
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '차에서 받은 내용을 읽을 수 없어요.',
      );
    }
  }

  static (String, String)? _error(Object? decoded) {
    if (decoded is Map && decoded['error'] is Map) {
      final error = decoded['error'] as Map;
      final code = error['code'];
      final message = error['message'];
      if (code is String) return (code, message is String ? message : '');
    }
    return null;
  }

  Future<KovaGatewayHealth> health() async {
    final response = await _guard(
      () => transport.get(_uri('/v1/health'), timeout),
    );
    if (_accessError(response) case final error?) throw error;
    if (response.statusCode != 200) {
      throw KovaParamsException(
        KovaFailureKind.http,
        '차에 연결하지 못했어요. 잠시 뒤 다시 해 주세요.',
        statusCode: response.statusCode,
      );
    }
    final json = _decode(response.body);
    if (json is! Map || json['status'] is! String) {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '차에서 받은 내용을 읽을 수 없어요.',
      );
    }
    final major = kovaSchemaMajor(json['schemaVersion']);
    if (major != supportedKovaParamsSchema) {
      throw const KovaParamsException(
        KovaFailureKind.schema,
        '차의 kovapilot 버전과 맞지 않아요. 앱을 업데이트해 주세요.',
      );
    }
    return KovaGatewayHealth(
      status: json['status'] as String,
      schemaVersion: major!,
      bindScope: json['bindScope'] is String
          ? json['bindScope'] as String
          : null,
      authentication: json['authentication'] is String
          ? json['authentication'] as String
          : null,
    );
  }

  KovaParamsDocument _document(Object? json) {
    try {
      return KovaParamsDocument.fromJson(json);
    } on KovaParamsSchemaUnsupported catch (error) {
      throw KovaParamsException(KovaFailureKind.schema, error.message);
    } on KovaParamsFormatException {
      // The parser's reason is for developers; the screen gets one line.
      throw const KovaParamsException(
        KovaFailureKind.format,
        '차에서 받은 설정을 읽을 수 없어요.',
      );
    }
  }

  Future<KovaParamsDocument> fetch() async {
    final response = await _guard(
      () => transport.get(_uri('/v1/kova-params'), timeout),
    );
    if (_accessError(response) case final error?) throw error;
    final json = _decode(response.body);
    if (response.statusCode != 200) {
      final error = _error(json);
      throw KovaParamsException(
        KovaFailureKind.http,
        error == null
            ? '설정을 불러오지 못했어요. 잠시 뒤 다시 해 주세요.'
            : kovaRejectionReason(error.$1, error.$2),
        statusCode: response.statusCode,
      );
    }
    return _document(json);
  }

  Future<KovaUpdateOutcome> update(
    String key,
    Object? value,
    int expectedRevision,
  ) async {
    final body = jsonEncode({
      'key': key,
      'value': value,
      'expectedRevision': expectedRevision,
    });
    final KovaHttpResponse response;
    try {
      response = await _guard(
        () => transport.postJson(_uri('/v1/kova-params/update'), body, timeout),
      );
    } on KovaParamsException catch (error) {
      return error.kind == KovaFailureKind.timeout
          ? const KovaUpdateTimedOut()
          : KovaUpdateFailed(error.message);
    }
    final Object? json;
    try {
      json = _decode(response.body);
    } on KovaParamsException catch (error) {
      return KovaUpdateFailed(error.message);
    }
    if (response.statusCode == 200) {
      try {
        return KovaUpdateApplied(_document(json));
      } on KovaParamsException catch (error) {
        return KovaUpdateFailed(error.message);
      }
    }
    final error = _error(json);
    if (error == null) {
      return const KovaUpdateFailed('차에서 받은 내용을 읽을 수 없어요.');
    }
    if (response.statusCode == 409 && error.$1 == 'revision_conflict') {
      return const KovaUpdateConflict();
    }
    return KovaUpdateRejected(
      code: error.$1,
      statusCode: response.statusCode,
      reason: kovaRejectionReason(error.$1, error.$2),
    );
  }

  void close() => transport.close();
}
