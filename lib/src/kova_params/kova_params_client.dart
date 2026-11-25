// HTTP client for the kovapilot gateway settings API (docs/PROTOCOL.md,
// "Settings HTTP"). No request is ever treated as successful unless the
// gateway answered 200 with an authoritative document.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_document.dart';
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
/// request is aborted.
class IoKovaParamsTransport implements KovaParamsTransport {
  IoKovaParamsTransport({HttpClient? client})
    : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 3);
    // Never use a system proxy for a local device.
    _client.findProxy = (_) => 'DIRECT';
  }

  static const maxBodyBytes = 1024 * 1024;
  final HttpClient _client;

  Future<KovaHttpResponse> _send(
    Future<HttpClientRequest> Function() open,
    Duration timeout, [
    String? body,
  ]) async {
    HttpClientRequest? request;
    Future<KovaHttpResponse> run() async {
      request = await open();
      request!.headers.set(HttpHeaders.acceptHeader, 'application/json');
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
  void close() => _client.close(force: true);
}

enum KovaFailureKind { timeout, transport, http, format, schema }

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
      '주행 중에는 바꿀 수 없어요. 차를 세우고(오프로드) 다시 해 주세요.',
    'update_forbidden' when lower.contains('read-only') =>
      '이 항목은 장치에서 읽기 전용이에요.',
    'update_forbidden' => '장치가 이 변경을 허용하지 않았어요.',
    'invalid_value' when lower.contains('unknown setting') =>
      '장치가 모르는 항목이에요. 목록을 다시 읽어 주세요.',
    'invalid_value' when lower.contains('out of range') =>
      '장치가 허용하는 범위를 벗어난 값이에요.',
    'invalid_value' => '장치가 받을 수 없는 값이에요.',
    'invalid_request' || 'invalid_json' => '요청 형식이 맞지 않아 장치가 거절했어요.',
    'kova_params_unavailable' => '장치의 설정 저장 상태를 확인할 수 없어요.',
    _ => '장치가 변경을 거절했어요.',
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
        '장치가 제때 답하지 않았어요.',
      );
    } on FormatException {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '장치 응답을 읽을 수 없어요.',
      );
    } on IOException {
      throw const KovaParamsException(
        KovaFailureKind.transport,
        '장치에 연결할 수 없어요.',
      );
    }
  }

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '장치 응답이 JSON이 아니에요.',
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
    if (response.statusCode != 200) {
      throw KovaParamsException(
        KovaFailureKind.http,
        '장치 상태 확인이 실패했어요 (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    final json = _decode(response.body);
    if (json is! Map || json['status'] is! String) {
      throw const KovaParamsException(
        KovaFailureKind.format,
        '장치 상태 응답 형식이 달라요.',
      );
    }
    final major = kovaSchemaMajor(json['schemaVersion']);
    if (major != supportedKovaParamsSchema) {
      throw const KovaParamsException(
        KovaFailureKind.schema,
        '장치의 API 버전을 이 앱이 지원하지 않아요. 앱을 업데이트해 주세요.',
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
    } on KovaParamsFormatException catch (error) {
      throw KovaParamsException(KovaFailureKind.format, error.message);
    }
  }

  Future<KovaParamsDocument> fetch() async {
    final response = await _guard(
      () => transport.get(_uri('/v1/kova-params'), timeout),
    );
    final json = _decode(response.body);
    if (response.statusCode != 200) {
      final error = _error(json);
      throw KovaParamsException(
        KovaFailureKind.http,
        error == null
            ? '설정을 읽지 못했어요 (HTTP ${response.statusCode}).'
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
      return KovaUpdateFailed('장치 응답 형식이 달라요 (HTTP ${response.statusCode}).');
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
