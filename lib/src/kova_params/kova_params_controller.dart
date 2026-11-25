// State for the "kovapilot 설정" tab: connection to the gateway settings
// API, the last authoritative document, per-setting "보내는 중" state and
// the write lock.
//
// Write lock (decision pending, see docs/PROTOCOL.md): the gateway has no
// pairing or authentication yet and binds only to loopback. KovaLink
// therefore sends writes only when the settings address is loopback
// (`127.0.0.1`, `::1`, `localhost`) — a development connection on the same
// machine — or when [isAuthenticated] reports a paired session (always false
// until pairing exists). Any LAN address stays read-only.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

enum KovaLinkStatus { disconnected, connecting, connected, stale }

enum KovaWriteLock {
  /// Writes are allowed (loopback development connection or paired).
  none,

  /// No document has been read yet.
  notConnected,

  /// Last refresh failed; values may be old.
  stale,

  /// LAN address without pairing: read-only.
  needsPairing,
}

enum KovaNoticeKind { sending, applied, rejected, conflict, timedOut, failed }

class KovaSettingNotice {
  const KovaSettingNotice(this.kind, this.message);
  final KovaNoticeKind kind;
  final String message;
}

typedef KovaClientFactory =
    KovaParamsClient? Function(
      String endpoint,
      void Function(String error) onError,
    );

class KovaParamsController extends ChangeNotifier {
  KovaParamsController({
    KovaClientFactory? clientFactory,
    this.pollInterval = const Duration(seconds: 15),
    this.staleAfter = const Duration(seconds: 45),
    DateTime Function()? clock,
    bool Function()? isAuthenticated,
  }) : _clientFactory =
           clientFactory ??
           ((endpoint, onError) =>
               KovaParamsClient.tryCreate(endpoint, onError: onError)),
       _clock = clock ?? DateTime.now,
       _isAuthenticated = isAuthenticated ?? (() => false);

  final KovaClientFactory _clientFactory;
  final DateTime Function() _clock;
  final bool Function() _isAuthenticated;

  /// Background re-read while connected; null disables polling (tests).
  final Duration? pollInterval;

  /// A document older than this is shown as "오래됨".
  final Duration staleAfter;

  KovaParamsClient? _client;
  Timer? _poll;
  int _generation = 0;
  int _failures = 0;
  bool _disposed = false;

  String? endpoint;
  KovaLinkStatus _status = KovaLinkStatus.disconnected;
  KovaParamsDocument? document;
  KovaGatewayHealth? health;
  DateTime? lastReadAt;

  /// Last connection/read problem, Korean.
  String? error;

  /// Values sent but not yet confirmed by the gateway.
  final Map<String, Object?> pending = {};

  /// Last outcome per setting key.
  final Map<String, KovaSettingNotice> notices = {};

  KovaLinkStatus get status {
    if (_status == KovaLinkStatus.connected &&
        lastReadAt != null &&
        _clock().difference(lastReadAt!) > staleAfter) {
      return KovaLinkStatus.stale;
    }
    return _status;
  }

  bool get isLoopback {
    final client = _client;
    return client != null &&
        LocalEndpointPolicy.isLoopbackHost(client.baseUri.host);
  }

  KovaWriteLock get writeLock {
    if (document == null || _client == null) return KovaWriteLock.notConnected;
    if (status == KovaLinkStatus.stale) return KovaWriteLock.stale;
    if (isLoopback || _isAuthenticated()) return KovaWriteLock.none;
    return KovaWriteLock.needsPairing;
  }

  static String writeLockReason(KovaWriteLock lock) => switch (lock) {
    KovaWriteLock.none => '',
    KovaWriteLock.notConnected => '장치에 연결하면 바꿀 수 있어요.',
    KovaWriteLock.stale => '장치와 연결이 불안정해 다시 읽을 때까지 잠갔어요.',
    KovaWriteLock.needsPairing =>
      '장치 pairing 전에는 읽기만 할 수 있어요. 지금은 같은 기기(loopback) 개발 연결에서만 바꿀 수 있어요.',
  };

  /// Per-setting line; the connection card shows [writeLockReason].
  static String _shortLockReason(KovaWriteLock lock) => switch (lock) {
    KovaWriteLock.none => '',
    KovaWriteLock.notConnected => '연결하면 바꿀 수 있어요.',
    KovaWriteLock.stale => '다시 읽을 때까지 잠겼어요.',
    KovaWriteLock.needsPairing => 'pairing 전이라 읽기 전용이에요.',
  };

  /// Why [setting] cannot be changed now, or null when it can.
  String? lockReasonFor(KovaParamSetting setting) {
    final lock = writeLock;
    if (lock != KovaWriteLock.none) return _shortLockReason(lock);
    if (setting.control == KovaParamControl.readOnly) {
      return '장치에서 읽기 전용으로 정한 항목이에요.';
    }
    if (setting.status == KovaAvailability.unsupported) {
      return '이 차량에서는 지원하지 않는 항목이에요.';
    }
    final onroad = document?.deviceOffroad == false;
    if (onroad &&
        (setting.applyPolicy == KovaApplyPolicy.offroad ||
            setting.applyPolicy == KovaApplyPolicy.restart)) {
      return '주행 중에는 바꿀 수 없어요. 차를 세운 뒤 바꿔 주세요.';
    }
    if (pending.containsKey(setting.key)) return '보내는 중이에요.';
    return null;
  }

  /// Connects to the settings origin: health check, then the document.
  Future<String?> connect(String address) async {
    _closeClient();
    final generation = ++_generation;
    String? policyError;
    final client = _clientFactory(address, (e) => policyError = e);
    if (client == null) {
      error = policyError ?? '올바른 설정 주소가 아니에요.';
      _status = KovaLinkStatus.disconnected;
      _notify();
      return error;
    }
    _client = client;
    endpoint = address.trim();
    _status = KovaLinkStatus.connecting;
    error = null;
    document = null;
    pending.clear();
    notices.clear();
    _notify();
    try {
      health = await client.health();
      if (generation != _generation) return null;
      await _read(client);
      if (generation != _generation) return null;
      _status = KovaLinkStatus.connected;
      _failures = 0;
      _schedulePoll();
      _notify();
      return null;
    } on KovaParamsException catch (e) {
      if (generation != _generation) return null;
      error = e.message;
      _status = KovaLinkStatus.disconnected;
      _closeClient();
      _notify();
      return error;
    }
  }

  Future<void> _read(KovaParamsClient client) async {
    document = await client.fetch();
    lastReadAt = _clock();
  }

  /// Re-reads the document. Failure keeps the last document as "오래됨".
  Future<bool> refresh() async {
    final client = _client;
    if (client == null) return false;
    final generation = _generation;
    try {
      await _read(client);
      if (generation != _generation) return false;
      _status = KovaLinkStatus.connected;
      error = null;
      _failures = 0;
      _schedulePoll();
      _notify();
      return true;
    } on KovaParamsException catch (e) {
      if (generation != _generation) return false;
      error = e.message;
      if (e.kind == KovaFailureKind.schema) {
        // Unknown major schema: close instead of showing old values.
        document = null;
        _status = KovaLinkStatus.disconnected;
        _closeClient();
      } else {
        _status = KovaLinkStatus.stale;
        _failures++;
        _schedulePoll();
      }
      _notify();
      return false;
    }
  }

  void disconnect() {
    _generation++;
    _closeClient();
    endpoint = null;
    document = null;
    health = null;
    lastReadAt = null;
    error = null;
    pending.clear();
    notices.clear();
    _status = KovaLinkStatus.disconnected;
    _notify();
  }

  /// Sends one change. The screen shows "보내는 중" until the gateway
  /// answers; only a 200 document changes the confirmed value.
  Future<KovaUpdateOutcome?> setValue(String key, Object? value) async {
    final client = _client;
    final current = document;
    final setting = current?.setting(key);
    if (client == null || current == null || setting == null) return null;
    if (lockReasonFor(setting) != null) return null;
    final localError = setting.check(value);
    if (localError != null) {
      notices[key] = KovaSettingNotice(KovaNoticeKind.rejected, localError);
      _notify();
      return null;
    }
    final generation = _generation;
    pending[key] = value;
    notices[key] = const KovaSettingNotice(KovaNoticeKind.sending, '보내는 중…');
    _notify();

    final outcome = await client.update(key, value, current.revision);
    if (generation != _generation) return outcome;
    pending.remove(key);
    final locale = current.defaultLocale;
    switch (outcome) {
      case KovaUpdateApplied(:final document):
        this.document = document;
        lastReadAt = _clock();
        _status = KovaLinkStatus.connected;
        final confirmed = document.setting(key);
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.applied,
          confirmed == null
              ? '장치가 저장했어요.'
              : '장치가 저장했어요: ${confirmed.describe(confirmed.value, defaultLocale: locale)}',
        );
      case KovaUpdateConflict():
        final ok = await refresh();
        final latest = document?.setting(key);
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.conflict,
          ok && latest != null
              ? '다른 곳에서 먼저 바뀌어 최신 값으로 다시 읽었어요 (지금 값: '
                    '${latest.describe(latest.value, defaultLocale: locale)}'
                    '${latest.value == setting.value ? '' : ', 이전: ${setting.describe(setting.value, defaultLocale: locale)}'}'
                    '). 필요하면 다시 골라 주세요.'
              : '다른 곳에서 먼저 바뀌었어요. 다시 읽기를 눌러 최신 값을 확인해 주세요.',
        );
      case KovaUpdateRejected(:final reason, :final code):
        notices[key] = KovaSettingNotice(KovaNoticeKind.rejected, reason);
        if (code == 'update_forbidden' || code == 'invalid_value') {
          await refresh();
        }
      case KovaUpdateTimedOut():
        final ok = await refresh();
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.timedOut,
          ok
              ? '응답이 늦어 저장됐는지 몰라 장치 값을 다시 읽었어요. 지금 보이는 값이 장치 값이에요.'
              : '응답이 없어 저장됐는지 알 수 없어요. 연결되면 장치 값을 다시 읽어요.',
        );
      case KovaUpdateFailed():
        final ok = await refresh();
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.failed,
          ok
              ? '보내는 중 통신이 끊겨 장치 값을 다시 읽었어요. 지금 보이는 값이 장치 값이에요.'
              : '보내지 못했어요. 연결되면 장치 값을 다시 읽어요.',
        );
    }
    _notify();
    return outcome;
  }

  void _schedulePoll() {
    _poll?.cancel();
    final interval = pollInterval;
    if (interval == null || _client == null || _disposed) return;
    // Back off while failing: 2, 4, 8 … up to the poll interval.
    final delay = _failures == 0
        ? interval
        : Duration(
            milliseconds: math.min(
              2000 * (1 << math.min(_failures - 1, 4)),
              interval.inMilliseconds,
            ),
          );
    _poll = Timer(delay, () {
      if (pending.isEmpty) {
        refresh();
      } else {
        _schedulePoll();
      }
    });
  }

  void _closeClient() {
    _poll?.cancel();
    _poll = null;
    _client?.close();
    _client = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _closeClient();
    super.dispose();
  }
}
