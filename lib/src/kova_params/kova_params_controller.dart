// State for the "kovapilot 설정" tab: connection to the gateway settings
// API, the last authoritative document, per-setting "보내는 중" state and
// the write lock.
//
// Write lock (docs/PROTOCOL.md): writes are sent only on a loopback
// development connection or when a pinned Wi-Fi session and /v1/health
// agree on the access method. The Gateway reports which settings are writable.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';
import 'package:kovalink/src/network/gateway_session.dart';
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
    this.pollInterval = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 45),
    DateTime Function()? clock,
    bool Function()? isAuthenticated,
    this.sessionFor,
  }) : _clientFactory =
           clientFactory ??
           ((endpoint, onError) =>
               KovaParamsClient.tryCreate(endpoint, onError: onError)),
       _clock = clock ?? DateTime.now,
       _isAuthenticated = isAuthenticated ?? (() => false);

  final KovaClientFactory _clientFactory;
  final DateTime Function() _clock;
  final bool Function() _isAuthenticated;

  /// The open session to the comma at a settings address (the app's
  /// registered comma), used when [connect] is not given one.
  final GatewaySession? Function(String address)? sessionFor;

  GatewaySession? _session;
  bool _sessionAuthenticated = false;

  /// Why the last connect or read failed, or null.
  KovaFailureKind? lastFailure;

  /// True on a Wi-Fi session the comma authenticated.
  bool get isAuthenticatedSession => _sessionAuthenticated;

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
    if (isLoopback || _sessionAuthenticated || _isAuthenticated()) {
      return KovaWriteLock.none;
    }
    return KovaWriteLock.needsPairing;
  }

  static String writeLockReason(KovaWriteLock lock) => switch (lock) {
    KovaWriteLock.none => '',
    KovaWriteLock.notConnected => '연결하면 바꿀 수 있어요.',
    KovaWriteLock.stale => '다시 연결될 때까지 바꿀 수 없어요.',
    KovaWriteLock.needsPairing => '이 연결에는 설정을 바꿀 권한이 없어요.',
  };

  /// Per-setting line; the connection card shows [writeLockReason].
  static String _shortLockReason(KovaWriteLock lock) => switch (lock) {
    KovaWriteLock.none => '',
    KovaWriteLock.notConnected => '연결하면 바꿀 수 있어요.',
    KovaWriteLock.stale => '다시 연결될 때까지 바꿀 수 없어요.',
    KovaWriteLock.needsPairing => '보기만 할 수 있어요.',
  };

  /// Why [setting] cannot be changed now, or null when it can.
  String? lockReasonFor(
    KovaParamSetting setting, {
    bool alreadySending = false,
  }) {
    final lock = writeLock;
    if (lock != KovaWriteLock.none) return _shortLockReason(lock);
    if (setting.status == KovaAvailability.unsupported) {
      if (setting.key == 'cruise.curve_slowdown') {
        return '이 차량에서는 커브 감속을 사용할 수 없어요.';
      }
      return '이 차에서는 쓸 수 없는 기능이에요.';
    }
    if (setting.control == KovaParamControl.readOnly) {
      if (setting.status == KovaAvailability.pendingConsumer) {
        return '아직 차량에 적용할 수 없는 기능이에요.';
      }
      if (setting.access == KovaParamAccess.readOnly &&
          setting.risk == KovaRisk.control &&
          health?.authentication == 'localNetwork') {
        return '소유자 인증 연결에서 바꿀 수 있는 제어 설정이에요.';
      }
      return '읽기 전용 항목이에요.';
    }
    if (setting.saveParkedOnly && document?.deviceParked != true) {
      return 'P에 두고 완전히 정차한 뒤 제어를 해제해 주세요.';
    }
    if (!setting.saveAnytime &&
        setting.applyPolicy == KovaApplyPolicy.parked &&
        document?.deviceParked != true &&
        document?.deviceOffroad != true) {
      return 'P에 두고 완전히 정차한 뒤 바꿀 수 있어요.';
    }
    final onroad = document?.deviceOffroad == false;
    if (!setting.saveAnytime &&
        !setting.saveParkedOnly &&
        onroad &&
        (setting.applyPolicy == KovaApplyPolicy.offroad ||
            setting.applyPolicy == KovaApplyPolicy.restart)) {
      return '시동을 끈 뒤 바꿀 수 있어요.';
    }
    if (!alreadySending && pending.containsKey(setting.key)) return '보내는 중이에요.';
    return null;
  }

  /// Connects to the settings origin: health check, then the document.
  /// A comma on Wi-Fi goes through [session] (or [sessionFor]): its pinned
  /// client and token.
  Future<String?> connect(String address, {GatewaySession? session}) async {
    _closeClient();
    final generation = ++_generation;
    String? policyError;
    final candidate = session ?? sessionFor?.call(address.trim());
    final open =
        candidate != null &&
            !candidate.isClosed &&
            LocalEndpointPolicy.validateSettings(address) == null &&
            candidate.covers(LocalEndpointPolicy.settingsBase(address))
        ? candidate
        : null;
    final KovaParamsClient? client;
    if (open != null) {
      client = KovaParamsClient(
        LocalEndpointPolicy.settingsBase(address),
        transport: open.transport,
      );
    } else {
      client = _clientFactory(address, (e) => policyError = e);
    }
    if (client == null) {
      error = policyError ?? '주소를 다시 확인해 주세요.';
      _status = KovaLinkStatus.disconnected;
      _notify();
      return error;
    }
    _client = client;
    _session = open;
    _sessionAuthenticated = false;
    lastFailure = null;
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
      final authentication = _session?.wifiAuthentication;
      _sessionAuthenticated =
          authentication != null &&
          health?.bindScope == 'wifi' &&
          health?.authentication == authentication;
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
      lastFailure = e.kind;
      _status = KovaLinkStatus.disconnected;
      _closeClient();
      _notify();
      return error;
    }
  }

  Future<void> _read(KovaParamsClient client) async {
    final fetched = await client.fetch();
    if (_client != client) return;
    document = fetched;
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
      lastFailure = e.kind;
      if (e.kind == KovaFailureKind.schema ||
          e.kind == KovaFailureKind.identity ||
          e.kind == KovaFailureKind.unauthorized) {
        // Unknown major schema, another comma or a refused token: close
        // instead of showing old values.
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
  Future<KovaUpdateOutcome?> setValue(
    String key,
    Object? value, {
    KovaParamSetting? reviewedSetting,
  }) async {
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

    final refreshed = await refresh();
    if (generation != _generation) return null;
    if (!refreshed) {
      pending.remove(key);
      const message = '콤마의 현재 설정을 확인하지 못해 저장하지 않았어요.';
      notices[key] = const KovaSettingNotice(KovaNoticeKind.failed, message);
      _notify();
      return const KovaUpdateFailed(message);
    }
    final latest = document!;
    final refreshedSetting = latest.setting(key);
    final reviewed = reviewedSetting ?? setting;
    if (refreshedSetting == null ||
        refreshedSetting.value != reviewed.value ||
        refreshedSetting.type != reviewed.type ||
        refreshedSetting.risk != reviewed.risk ||
        refreshedSetting.applyPolicy != reviewed.applyPolicy) {
      pending.remove(key);
      notices[key] = KovaSettingNotice(
        KovaNoticeKind.conflict,
        refreshedSetting == null
            ? '콤마의 설정 항목이 바뀌었어요. 다시 확인해 주세요.'
            : '다른 곳에서 먼저 바뀌었어요. 지금 값: '
                  '${refreshedSetting.describe(refreshedSetting.value, defaultLocale: latest.defaultLocale)}'
                  '${refreshedSetting.value == reviewed.value ? '' : ', 이전: ${reviewed.describe(reviewed.value, defaultLocale: current.defaultLocale)}'}',
      );
      _notify();
      return const KovaUpdateConflict();
    }
    final lock = lockReasonFor(refreshedSetting, alreadySending: true);
    final rejection = lock ?? refreshedSetting.check(value);
    if (rejection != null) {
      pending.remove(key);
      notices[key] = KovaSettingNotice(KovaNoticeKind.rejected, rejection);
      _notify();
      return KovaUpdateRejected(
        code: lock == null ? 'invalid_value' : 'update_forbidden',
        statusCode: lock == null ? 400 : 403,
        reason: rejection,
      );
    }
    final outcome = await client.update(
      key,
      value,
      latest.revision,
      expectedValue: key == 'cruise.openpilot_longitudinal'
          ? refreshedSetting.value
          : null,
    );
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
              ? '저장했어요.'
              : '저장했어요: ${confirmed.describe(confirmed.value, defaultLocale: locale)}',
        );
      case KovaUpdateConflict():
        final ok = await refresh();
        final latest = document?.setting(key);
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.conflict,
          ok && latest != null
              ? '다른 곳에서 먼저 바뀌었어요. 지금 값: '
                    '${latest.describe(latest.value, defaultLocale: locale)}'
                    '${latest.value == setting.value ? '' : ', 이전: ${setting.describe(setting.value, defaultLocale: locale)}'}'
              : '다른 곳에서 먼저 바뀌었어요. 새로고침해서 확인해 주세요.',
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
              ? '응답이 늦어 차에 저장된 값을 다시 불러왔어요.'
              : '응답이 없어 저장됐는지 알 수 없어요. 다시 연결되면 차의 값을 불러와요.',
        );
      case KovaUpdateFailed():
        final ok = await refresh();
        notices[key] = KovaSettingNotice(
          KovaNoticeKind.failed,
          ok
              ? '연결이 잠깐 끊겨 차에 저장된 값을 다시 불러왔어요.'
              : '보내지 못했어요. 다시 연결되면 차의 값을 불러와요.',
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
    // A session's transport leaves the shared client open.
    _client?.close();
    _client = null;
    _session = null;
    _sessionAuthenticated = false;
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
