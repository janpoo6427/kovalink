// Registering this phone as the comma's owner on automatic Wi-Fi: the comma
// shows a six-digit code on its screen (kovapilot master-jh
// `POST /v1/owner/pair`), the code typed here returns the owner token once
// (`POST /v1/owner/confirm`). The token never leaves the token store.
import 'dart:convert';

import 'package:kovalink/src/network/gateway_session.dart';

sealed class OwnerCodeRequest {
  const OwnerCodeRequest();
}

/// The comma shows a code for [seconds].
class OwnerCodeShown extends OwnerCodeRequest {
  const OwnerCodeShown(this.seconds);
  final int seconds;
}

class OwnerCodeRefused extends OwnerCodeRequest {
  const OwnerCodeRefused(this.message);

  /// Korean, user-facing.
  final String message;
}

sealed class OwnerCodeResult {
  const OwnerCodeResult();
}

class OwnerCodeAccepted extends OwnerCodeResult {
  const OwnerCodeAccepted(this.token);
  final String token;
}

class OwnerCodeWrong extends OwnerCodeResult {
  const OwnerCodeWrong(this.remaining);
  final int? remaining;
}

class OwnerCodeFailed extends OwnerCodeResult {
  const OwnerCodeFailed(this.message);

  /// Korean, user-facing.
  final String message;
}

abstract final class OwnerPairingText {
  static const offroad = '시동을 끈 상태에서 등록해 주세요.';
  static const busy = '방금 코드를 받았어요. 잠시 뒤 다시 눌러 주세요.';
  static const unsupported =
      '이 콤마의 kovapilot은 앱에서 소유자 등록을 할 수 없어요. kovapilot을 업데이트해 주세요.';
  static const expired = '코드 시간이 지났어요. 새 코드를 받아 주세요.';
  static const failed = '콤마에 연결하지 못했어요. 같은 Wi-Fi인지 확인하고 다시 해 주세요.';
}

class OwnerPairingClient {
  const OwnerPairingClient(
    this.session, {
    this.timeout = const Duration(seconds: 8),
  });

  final GatewaySession session;
  final Duration timeout;

  static final codePattern = RegExp(r'^[0-9]{6}$');
  static final _tokenPattern = RegExp(r'^[0-9a-f]{64}$');

  Uri _uri(String path) => Uri.parse('${session.endpoints.origin}$path');

  static String? _code(String body) {
    try {
      final json = jsonDecode(body);
      final error = json is Map ? json['error'] : null;
      final code = error is Map ? error['code'] : null;
      return code is String ? code : null;
    } on FormatException {
      return null;
    }
  }

  Future<OwnerCodeRequest> requestCode() async {
    try {
      final response = await session.transport.postJson(
        _uri('/v1/owner/pair'),
        '{}',
        timeout,
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final seconds = json is Map ? json['expiresIn'] : null;
        return OwnerCodeShown(seconds is int && seconds > 0 ? seconds : 120);
      }
      return OwnerCodeRefused(switch (response.statusCode) {
        409 => OwnerPairingText.offroad,
        429 => OwnerPairingText.busy,
        404 || 405 => OwnerPairingText.unsupported,
        _ => OwnerPairingText.failed,
      });
    } on Exception {
      return const OwnerCodeRefused(OwnerPairingText.failed);
    }
  }

  Future<OwnerCodeResult> confirm(String code) async {
    if (!codePattern.hasMatch(code)) return const OwnerCodeWrong(null);
    try {
      final response = await session.transport.postJson(
        _uri('/v1/owner/confirm'),
        jsonEncode({'code': code}),
        timeout,
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final token = json is Map ? json['token'] : null;
        if (token is String && _tokenPattern.hasMatch(token)) {
          return OwnerCodeAccepted(token);
        }
        return const OwnerCodeFailed(OwnerPairingText.failed);
      }
      if (response.statusCode == 403 &&
          _code(response.body) == 'owner_pairing_code_invalid') {
        final json = jsonDecode(response.body);
        final error = json is Map ? json['error'] : null;
        final remaining = error is Map ? error['remainingAttempts'] : null;
        return OwnerCodeWrong(remaining is int ? remaining : null);
      }
      return OwnerCodeFailed(switch (response.statusCode) {
        410 => OwnerPairingText.expired,
        409 => OwnerPairingText.offroad,
        404 || 405 => OwnerPairingText.unsupported,
        _ => OwnerPairingText.failed,
      });
    } on Exception {
      return const OwnerCodeFailed(OwnerPairingText.failed);
    }
  }
}
