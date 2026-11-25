// HTTP client for the kovapilot gateway Git maintenance API (read-only
// inspection and switch/reset previews). Errors become one plain Korean line;
// the gateway's own message is never shown.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kovalink/src/kova_params/kova_params_client.dart'
    show IoKovaParamsTransport, KovaHttpResponse, KovaParamsTransport;
import 'package:kovalink/src/kovapilot_git/git_models.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

enum KovaGitFailure {
  /// No answer in time.
  timeout,

  /// Nothing reachable at the address (refused, unreachable, reset).
  transport,

  /// 403 `local_client_required`: a kovapilot gateway answered but only
  /// accepts clients on the comma itself for now.
  localOnly,

  /// 503 `git_busy`: another inspection is running on the comma.
  busy,

  /// 503 `git_unavailable`: the comma could not read its checkout.
  unavailable,

  /// 400 `invalid_git_request`: unknown branch, bad or unreachable commit.
  invalidRequest,

  /// 403 `git_mutation_disabled`: apply is not allowed yet.
  mutationDisabled,

  /// 404/405: this kovapilot has no Git maintenance API.
  unsupported,

  /// The answer did not match the contract.
  format,

  /// 401: the comma refused the token.
  unauthorized,

  /// 403 `wifi_client_required`: the comma refused this phone.
  notAllowed,

  /// The certificate pin is not the registered comma's; nothing was sent.
  identity,

  /// Any other HTTP error.
  http,
}

class KovaGitException implements Exception {
  const KovaGitException(this.kind, this.message, {this.statusCode, this.code});
  final KovaGitFailure kind;

  /// Korean, user-facing.
  final String message;
  final int? statusCode;
  final String? code;

  /// Worth an automatic or manual retry soon.
  bool get retryable => switch (kind) {
    KovaGitFailure.timeout ||
    KovaGitFailure.transport ||
    KovaGitFailure.busy ||
    KovaGitFailure.unavailable => true,
    _ => false,
  };

  @override
  String toString() => message;
}

/// User-facing text for each failure. Kept together so screens and tests
/// agree on the wording.
abstract final class KovaGitText {
  static const timeout = '콤마에서 응답이 없어요. 잠시 뒤 다시 해 주세요.';
  static const transport = '콤마에 연결할 수 없어요. 같은 와이파이나 핫스팟에 있는지 확인해 주세요.';
  static const localOnly = '콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요.';
  static const localOnlyDetail =
      '지금 kovapilot은 콤마 안에서 여는 연결만 받아요. 휴대폰 연결이 열리면 이 화면을 쓸 수 있어요.';
  static const busy = '콤마가 다른 확인을 하고 있어요. 잠시 뒤 다시 해 주세요.';
  static const unavailable = '콤마에서 kovapilot 버전 정보를 읽지 못했어요. 잠시 뒤 다시 해 주세요.';
  static const invalidRequest = '콤마가 이 요청을 받지 않았어요. 브랜치나 커밋을 다시 골라 주세요.';
  static const mutationDisabled = '콤마에서 아직 바꾸기를 허용하지 않아요.';
  static const unsupported = '콤마의 kovapilot이 아직 이 기능을 지원하지 않아요.';
  static const format = '콤마에서 받은 내용을 읽을 수 없어요.';
  static const http = '콤마에서 요청을 처리하지 못했어요. 잠시 뒤 다시 해 주세요.';
}

/// Maps an HTTP status and gateway error code to a failure.
KovaGitException kovaGitError(int statusCode, String? code) =>
    switch ((statusCode, code)) {
      (401, _) => KovaGitException(
        KovaGitFailure.unauthorized,
        KovaLinkText.message(KovaLinkProblem.tokenRejected),
        statusCode: statusCode,
        code: code,
      ),
      (403, 'wifi_client_required') => KovaGitException(
        KovaGitFailure.notAllowed,
        KovaLinkText.message(KovaLinkProblem.notAllowed),
        statusCode: statusCode,
        code: code,
      ),
      (403, 'local_client_required') => KovaGitException(
        KovaGitFailure.localOnly,
        KovaGitText.localOnly,
        statusCode: statusCode,
        code: code,
      ),
      (403, 'git_mutation_disabled') => KovaGitException(
        KovaGitFailure.mutationDisabled,
        KovaGitText.mutationDisabled,
        statusCode: statusCode,
        code: code,
      ),
      (403, 'git_apply_blocked') => KovaGitException(
        KovaGitFailure.mutationDisabled,
        '작업 트리가 깨끗하고 업데이트가 쉬고 있을 때 적용할 수 있어요.',
        statusCode: statusCode,
        code: code,
      ),
      (409, 'git_plan_changed') => KovaGitException(
        KovaGitFailure.invalidRequest,
        '콤마나 원격 브랜치가 바뀌었어요. 미리보기를 다시 열어 주세요.',
        statusCode: statusCode,
        code: code,
      ),
      (503, 'git_busy') => KovaGitException(
        KovaGitFailure.busy,
        KovaGitText.busy,
        statusCode: statusCode,
        code: code,
      ),
      (503, 'git_unavailable') => KovaGitException(
        KovaGitFailure.unavailable,
        KovaGitText.unavailable,
        statusCode: statusCode,
        code: code,
      ),
      (400, 'invalid_git_request') => KovaGitException(
        KovaGitFailure.invalidRequest,
        KovaGitText.invalidRequest,
        statusCode: statusCode,
        code: code,
      ),
      (404 || 405, _) => KovaGitException(
        KovaGitFailure.unsupported,
        KovaGitText.unsupported,
        statusCode: statusCode,
        code: code,
      ),
      _ => KovaGitException(
        KovaGitFailure.http,
        KovaGitText.http,
        statusCode: statusCode,
        code: code,
      ),
    };

class KovaGitClient {
  KovaGitClient(
    this.baseUri, {
    KovaParamsTransport? transport,
    this.timeout = const Duration(seconds: 8),
  }) : transport = transport ?? IoKovaParamsTransport();

  /// Validates [endpoint] with the local-only policy first (same rule as the
  /// settings client: private, loopback or `.local` addresses only).
  static KovaGitClient? tryCreate(
    String endpoint, {
    KovaParamsTransport? transport,
    Duration timeout = const Duration(seconds: 8),
    void Function(String error)? onError,
  }) {
    final error = LocalEndpointPolicy.validateSettings(endpoint);
    if (error != null) {
      onError?.call(error);
      return null;
    }
    return KovaGitClient(
      LocalEndpointPolicy.settingsBase(endpoint),
      transport: transport,
      timeout: timeout,
    );
  }

  static const int maxLogLimit = 100;
  static const int maxLogCursor = 10000;

  final Uri baseUri;
  final KovaParamsTransport transport;

  /// Per request. The gateway runs a few bounded `git` commands per call.
  final Duration timeout;

  Uri _uri(String path, [Map<String, String>? query]) =>
      baseUri.replace(path: path, queryParameters: query);

  Future<Object?> _call(
    Future<KovaHttpResponse> Function() send, {
    int expectedStatus = 200,
  }) async {
    final KovaHttpResponse response;
    try {
      response = await send();
    } on TimeoutException {
      throw const KovaGitException(KovaGitFailure.timeout, KovaGitText.timeout);
    } on FormatException {
      throw const KovaGitException(KovaGitFailure.format, KovaGitText.format);
    } on GatewayIdentityMismatch {
      throw KovaGitException(
        KovaGitFailure.identity,
        KovaLinkText.message(KovaLinkProblem.identityMismatch),
      );
    } on GatewayOriginRefused {
      throw const KovaGitException(
        KovaGitFailure.transport,
        KovaGitText.transport,
      );
    } on IOException {
      throw const KovaGitException(
        KovaGitFailure.transport,
        KovaGitText.transport,
      );
    }
    Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      json = null;
    }
    if (response.statusCode != expectedStatus) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const KovaGitException(KovaGitFailure.format, KovaGitText.format);
      }
      String? code;
      if (json is Map && json['error'] is Map) {
        final value = (json['error'] as Map)['code'];
        if (value is String) code = value;
      }
      throw kovaGitError(response.statusCode, code);
    }
    if (json == null) {
      throw const KovaGitException(KovaGitFailure.format, KovaGitText.format);
    }
    return json;
  }

  T _parse<T>(Object? json, T Function(Object? json) parse) {
    try {
      return parse(json);
    } on KovaGitFormatException {
      throw const KovaGitException(KovaGitFailure.format, KovaGitText.format);
    }
  }

  Future<KovaGitStatus> status() async => _parse(
    await _call(() => transport.get(_uri('/v1/git/status'), timeout)),
    KovaGitStatus.fromJson,
  );

  Future<List<KovaGitBranch>> branches() async => _parse(
    await _call(() => transport.get(_uri('/v1/git/branches'), timeout)),
    parseKovaGitBranches,
  );

  /// One page of HEAD history. [limit] 1..100, [cursor] 0..10000 (the
  /// gateway's bounds; anything else is refused before sending).
  Future<KovaGitLogPage> log({int limit = 20, int cursor = 0}) async {
    if (limit < 1 ||
        limit > maxLogLimit ||
        cursor < 0 ||
        cursor > maxLogCursor) {
      throw const KovaGitException(
        KovaGitFailure.invalidRequest,
        KovaGitText.invalidRequest,
      );
    }
    return _parse(
      await _call(
        () => transport.get(
          _uri('/v1/git/log', {'limit': '$limit', 'cursor': '$cursor'}),
          timeout,
        ),
      ),
      KovaGitLogPage.fromJson,
    );
  }

  /// Preview of a switch or reset. A reset target must be a full SHA; a
  /// short one is refused before sending.
  Future<KovaGitPlan> plan(KovaGitPlanRequest request) async {
    if (request.operation == KovaGitOperation.reset &&
        !isFullCommitSha(request.commit)) {
      throw const KovaGitException(
        KovaGitFailure.invalidRequest,
        KovaGitText.invalidRequest,
      );
    }
    final body = jsonEncode(request.toJson());
    return _parse(
      await _call(
        () => transport.postJson(_uri('/v1/git/plan'), body, timeout),
      ),
      KovaGitPlan.fromJson,
    );
  }

  /// Submit a reviewed plan for the device updater to stage.
  Future<void> apply(String planDigest, {KovaGitPlanRequest? request}) async {
    final result = await _call(
      () => transport.postJson(
        _uri('/v1/git/apply'),
        jsonEncode({...?request?.toJson(), 'planDigest': planDigest}),
        timeout,
      ),
      expectedStatus: 202,
    );
    if (result is! Map ||
        result['maintenance'] is! Map ||
        (result['maintenance'] as Map)['phase'] != 'queued') {
      throw const KovaGitException(KovaGitFailure.format, KovaGitText.format);
    }
  }

  void close() => transport.close();
}
