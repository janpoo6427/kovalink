// Keeps looking for the kovapilot device (comma) until it answers, and
// watches it afterwards. KovaLink does little without the car, so this runs
// whenever the app is in the foreground and 자동 연결 is on.
//
// One search pass: last successful address → saved/known addresses and each
// network's `.1` router → announced addresses (mDNS, when any) → the rest
// of every Wi-Fi/hotspot /24 in parallel. A host counts only after
// `/v1/health` answers like a kovapilot gateway: on Wi-Fi that is the 401
// token challenge over TLS, asked without any token.
//
// A comma is connected on its own only when [AutoConnectController.canAttach]
// allows it: the registered comma (same certificate pin, at any address).
// Other commas are listed for the user to pick and register. Failed passes
// wait 1 → 2 → 5 → 10 → 15 s (cap). Nothing runs while the app is in the
// background or the screen is off.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/network/comma_advert_source.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';

enum AutoConnectPhase {
  /// 자동 연결 is off in settings.
  off,

  /// App in background / screen off.
  paused,

  /// A search pass is running.
  searching,

  /// Last pass found nothing; waiting for the next one.
  waiting,

  /// Several devices answered; the user picks one.
  choosing,

  /// A comma found here is connected and watched.
  connected,

  /// The comma answered but the connection needs the user: wrong token,
  /// another certificate, refused or another version ([problem]).
  needsAttention,
}

class AutoConnectLogEntry {
  const AutoConnectLogEntry(this.at, this.message);
  final DateTime at;
  final String message;

  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  @override
  String toString() => '$time $message';
}

/// What the app does with a device. Implemented by the app wiring; tests
/// use a recording fake.
abstract class AutoConnectTarget {
  /// True while the telemetry socket is live. Telemetry only ever opens to
  /// a comma found here (there is no address to type), so the controller
  /// does not act on it; it is kept for the app wiring and diagnostics.
  bool get isTelemetryLive;

  /// A device was confirmed: remember it and open settings, and telemetry
  /// unless [openTelemetry] is false (the user is watching the demo).
  Future<void> attach(KovaDevice device, {bool openTelemetry = true});

  /// Heartbeat passed: retry whatever is not open yet.
  Future<void> keepAlive(KovaDevice device, {bool openTelemetry = true});

  /// The device stopped answering.
  void detach(KovaDevice device);
}

class AutoConnectController extends ChangeNotifier {
  AutoConnectController({
    required this.target,
    DeviceProbe? probe,
    NetworkLister? listNetworks,
    this.lastEndpoint,
    this.knownEndpoints,
    bool Function(KovaDevice device)? canAttach,
    this.adverts,
    this.advertWait = const Duration(milliseconds: 1200),
    List<int> ports = const [kovaGatewayDefaultPort],
    List<int> Function()? portsProvider,
    this.concurrency = 24,
    this.backoff = defaultBackoff,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.networkWatchInterval = const Duration(seconds: 4),
    this.heartbeatFailuresBeforeLost = 2,
    this.maxLogEntries = 80,
    DateTime Function()? clock,
  }) : _probe = probe ?? GatewayDeviceProbe(),
       _listNetworks = listNetworks ?? listLocalNetworks,
       _ports = portsProvider ?? (() => ports),
       _canAttach = canAttach ?? ((_) => true),
       _clock = clock ?? DateTime.now;

  static const defaultBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
  ];

  final AutoConnectTarget target;
  final DeviceProbe _probe;
  final NetworkLister _listNetworks;
  final DateTime Function() _clock;
  final bool Function(KovaDevice device) _canAttach;

  /// Local service announcements (mDNS); null = not used.
  final CommaAdvertSource? adverts;

  /// How long one pass listens for announcements.
  final Duration advertWait;

  /// True when [device] may be connected without the user: the registered
  /// comma, or a loopback development gateway.
  bool canAttach(KovaDevice device) => _canAttach(device);

  /// Last successful settings origin (tried first).
  final String? Function()? lastEndpoint;

  /// Other saved settings origins (tried before the subnet scan).
  final List<String> Function()? knownEndpoints;
  final List<int> Function() _ports;

  /// Gateway ports probed on every candidate.
  List<int> get ports => _ports();
  final int concurrency;
  final List<Duration> backoff;
  final Duration heartbeatInterval;
  final Duration networkWatchInterval;
  final int heartbeatFailuresBeforeLost;
  final int maxLogEntries;

  AutoConnectPhase _phase = AutoConnectPhase.off;
  bool _enabled = false;
  bool _foreground = true;
  bool _disposed = false;
  int _generation = 0;
  int _failedPasses = 0;
  int _heartbeatFailures = 0;
  bool _heartbeatRunning = false;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  Timer? _watchTimer;
  bool _watchRunning = false;
  String? _networkSignature;

  /// Pass number since the last connection / network change (1-based).
  int attempt = 0;

  /// Delay before the next pass while [phase] is waiting.
  Duration? nextRetry;

  /// Networks seen by the last listing (including unscanned ones).
  List<LocalNetwork> networks = const [];

  /// Probes done / planned in the current pass.
  int probed = 0;
  int planned = 0;

  /// Ranges being scanned in the current pass (`a.b.c.x`).
  List<String> scanningSubnets = const [];

  /// Devices that answered in the current/last pass.
  List<KovaDevice> found = const [];

  /// Commas that answered but refused this phone (403).
  List<KovaDevice> refused = const [];

  /// Why the user is needed ([AutoConnectPhase.needsAttention]) or why the
  /// last pass found nobody to connect; null when all is well.
  KovaLinkProblem? problem;

  /// Commas that answered in the current/last pass but do not accept phones
  /// yet (403 `local_client_required`), by on-screen name.
  List<String> localOnly = const [];

  /// The device being watched; null when not connected.
  KovaDevice? device;

  /// The user left live telemetry on purpose (데모 보기). The comma is still
  /// found and watched and its settings stay open, but telemetry is not
  /// reopened behind the user's back until 지금 찾기 or turning 자동 연결
  /// off and on.
  bool telemetryHeld = false;

  final List<AutoConnectLogEntry> _log = [];

  /// Newest last.
  List<AutoConnectLogEntry> get log => List.unmodifiable(_log);

  AutoConnectPhase get phase => _phase;
  bool get enabled => _enabled;
  bool get foreground => _foreground;
  bool get _active => _enabled && _foreground && !_disposed;

  /// Total probes this controller has made (tests, diagnostics).
  int totalProbes = 0;

  /// Short status line for the road view.
  String get statusLabel => switch (_phase) {
    AutoConnectPhase.off => '자동 연결 꺼짐',
    AutoConnectPhase.paused => '자동 연결 멈춤',
    AutoConnectPhase.searching => '콤마 찾는 중 · $attempt번째',
    AutoConnectPhase.waiting when localOnly.isNotEmpty =>
      '콤마 찾음 · 휴대폰 연결 아직 허용 안 됨',
    AutoConnectPhase.waiting => '콤마 없음 · ${nextRetry?.inSeconds ?? 0}초 뒤 다시',
    AutoConnectPhase.choosing => '콤마 ${found.length}대 찾음',
    AutoConnectPhase.connected => '콤마 연결됨',
    AutoConnectPhase.needsAttention => '콤마 확인 필요',
  };

  // ---- inputs ----------------------------------------------------------

  void setEnabled(bool on) {
    if (_disposed || on == _enabled) return;
    _enabled = on;
    if (!on) {
      _stopAll();
      device = null;
      found = const [];
      refused = const [];
      problem = null;
      _phase = AutoConnectPhase.off;
      _add('자동 연결을 껐어요.');
      _notify();
      return;
    }
    _add('자동 연결을 켰어요.');
    telemetryHeld = false;
    _resume('앱 시작');
  }

  /// App lifecycle: false in background / screen off.
  void setForeground(bool value) {
    if (_disposed || value == _foreground) return;
    _foreground = value;
    if (!_enabled) return;
    if (!value) {
      _stopAll();
      _phase = AutoConnectPhase.paused;
      _add('화면이 꺼져서 찾기를 멈췄어요.');
      _notify();
      return;
    }
    _resume('앱 다시 열림');
  }

  /// "지금 찾기": starts a fresh pass right away.
  void retryNow() {
    if (!_active) return;
    device = null;
    telemetryHeld = false;
    problem = null;
    _kick('직접 다시 찾기', reset: true);
  }

  /// The user picked one of several devices. A comma that is not
  /// registered yet is registered first (the screen opens that form).
  Future<void> choose(KovaDevice chosen) async {
    if (!_active || !_canAttach(chosen)) return;
    _generation++;
    _retryTimer?.cancel();
    await _connect(chosen, '직접 고름');
  }

  /// Connects to [chosen] now (IP entry, or right after registering), also
  /// when 자동 연결 is off. Watching it needs 자동 연결 on.
  Future<void> connectTo(KovaDevice chosen, {String how = 'IP로 연결'}) async {
    if (_disposed || !_foreground || !_canAttach(chosen)) return;
    _generation++;
    _retryTimer?.cancel();
    await _connect(chosen, how);
  }

  /// Checks one address once (IP entry). Changes nothing.
  Future<ProbeResult> check(String host, int port) async {
    if (_disposed || !isPolicyTarget(host, port)) {
      return const ProbeResult.noAnswer();
    }
    final label = ProbeTarget(host, port, CandidateSource.known).displayName;
    _add('$label · 직접 넣은 IP를 확인해요');
    _notify();
    final result = await _probeOne(
      ProbeTarget(host, port, CandidateSource.known),
    );
    if (result.outcome == ProbeOutcome.noAnswer) _add('$label · 답이 없어요');
    _notify();
    return result;
  }

  /// The comma answered but the connection could not go on ([problem]):
  /// stop watching it and wait for the user (지금 찾기, register again).
  void hold(KovaDevice device, KovaLinkProblem problem) {
    if (_disposed) return;
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    nextRetry = null;
    if (this.device == device) this.device = null;
    if (!found.contains(device)) found = List.unmodifiable([...found, device]);
    this.problem = problem;
    _phase = AutoConnectPhase.needsAttention;
    _add('${device.displayName} · ${KovaLinkText.message(problem)}');
    _notify();
  }

  /// The telemetry socket dropped. Check the device right away; it is
  /// searched for again if it is gone.
  void connectionLost() {
    if (!_active || device == null) return;
    _add('주행 정보 연결이 끊겼어요. 콤마를 확인해요.');
    unawaited(_heartbeat(lossOnFirstFailure: true));
  }

  /// The user left live telemetry on purpose (데모 보기): keep the found comma
  /// but do not reopen telemetry until the user asks again.
  void telemetryLeftByUser() {
    if (!_active) return;
    telemetryHeld = true;
    _add('데모를 보는 동안에는 주행 정보를 다시 잇지 않아요.');
    _notify();
  }

  /// Telemetry to the found comma went live: a 데모 보기 hold is over.
  void telemetryConnected() {
    if (!telemetryHeld) return;
    telemetryHeld = false;
    _notify();
  }

  // ---- loop ------------------------------------------------------------

  void _resume(String reason) {
    _startWatch();
    if (device != null) {
      _phase = AutoConnectPhase.connected;
      _notify();
      _startHeartbeat();
      unawaited(_heartbeat());
      return;
    }
    _kick(reason, reset: true);
  }

  void _kick(String reason, {bool reset = false}) {
    if (!_active) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (reset) {
      _failedPasses = 0;
      attempt = 0;
    }
    final generation = ++_generation;
    unawaited(_pass(generation, reason));
  }

  Future<void> _pass(int generation, String reason) async {
    attempt++;
    _phase = AutoConnectPhase.searching;
    nextRetry = null;
    probed = 0;
    planned = 0;
    found = const [];
    localOnly = const [];
    refused = const [];
    problem = null;
    scanningSubnets = const [];
    _add('$attempt번째 찾기 시작 ($reason)');
    _notify();
    final announced = adverts?.lookup(advertWait);

    List<LocalNetwork> nets;
    try {
      nets = await _listNetworks();
    } on Object {
      nets = const [];
      _add('네트워크 정보를 읽지 못했어요.');
    }
    if (generation != _generation) return;
    networks = List.unmodifiable(nets);
    _networkSignature = _signature(nets);

    final scannable = nets.where((n) => n.scannable).toList();
    final plan = DiscoveryPlan.build(
      networks: nets,
      lastEndpoint: lastEndpoint?.call(),
      knownEndpoints: knownEndpoints?.call() ?? const [],
      ports: ports,
    );
    if (plan.isEmpty) {
      _add(
        scannable.isEmpty
            ? '연결된 와이파이·핫스팟이 없어요. 모바일 데이터로는 찾지 않아요.'
            : '검색할 주소가 없어요.',
      );
      _scheduleRetry(generation);
      return;
    }
    planned = plan.length;
    scanningSubnets = [for (final n in scannable) ?n.rangeLabel];
    _notify();

    final seen = <KovaDevice>[];
    Future<bool> tryPriority(ProbeTarget candidate) async {
      final result = await _probeOne(candidate);
      if (generation != _generation) return true;
      probed++;
      if (result.device case final device?) {
        if (_canAttach(device)) {
          await _connect(device, _sourceLabel(candidate.source));
          return true;
        }
        if (!seen.contains(device)) seen.add(device);
        found = List.unmodifiable(seen);
      } else if (candidate.source == CandidateSource.last) {
        _add('마지막 주소 ${candidate.displayName} · 답이 없어요');
      }
      _notify();
      return false;
    }

    for (final candidate in plan.priority) {
      if (await tryPriority(candidate)) return;
    }

    var scan = plan.scan;
    if (announced != null) {
      List<({String host, int port})> addresses;
      try {
        addresses = await announced;
      } on Object {
        addresses = const [];
      }
      if (generation != _generation) return;
      // Announced addresses go before the scan (and are not scanned again).
      final probedKeys = {for (final t in plan.priority) t.key};
      final scanKeys = {for (final t in scan) t.key};
      final extra =
          DiscoveryPlan.build(
                networks: nets,
                advertised: addresses,
                ports: ports,
                scanSubnets: false,
              ).priority
              .where(
                (t) =>
                    t.source == CandidateSource.advertised &&
                    !probedKeys.contains(t.key),
              )
              .toList();
      if (extra.isNotEmpty) {
        _add('콤마가 알린 주소 ${extra.length}곳을 먼저 확인해요.');
        final extraKeys = {for (final t in extra) t.key};
        scan = [
          for (final t in scan)
            if (!extraKeys.contains(t.key)) t,
        ];
        planned += extra.where((t) => !scanKeys.contains(t.key)).length;
      }
      for (final candidate in extra) {
        if (await tryPriority(candidate)) return;
      }
    }

    if (scan.isNotEmpty) {
      _add('${scanningSubnets.join(', ')}에서 ${plan.scan.length}곳을 찾아봐요.');
      _notify();
    }
    final scanned = await _scanParallel(scan, generation, seen);
    if (generation != _generation) return;
    final results = [
      ...seen,
      for (final d in scanned)
        if (!seen.contains(d)) d,
    ];
    final ready = results.where(_canAttach).toList();

    if (results.isEmpty) {
      if (refused.isNotEmpty) {
        problem = KovaLinkProblem.notAllowed;
        _add(KovaLinkText.message(KovaLinkProblem.notAllowed));
      } else if (localOnly.isNotEmpty) {
        _add('$kovaLocalOnlyMessage.');
      } else {
        problem = KovaLinkProblem.notFound;
        _add('콤마를 찾지 못했어요.');
      }
      _scheduleRetry(generation);
    } else if (ready.length == 1) {
      await _connect(ready.single, '네트워크 검색');
    } else {
      found = List.unmodifiable(results);
      _phase = AutoConnectPhase.choosing;
      if (ready.isEmpty) problem = KovaLinkProblem.needsRegistration;
      _add(
        ready.isEmpty
            ? '콤마 ${results.length}대를 찾았어요. 등록할 콤마를 골라 주세요.'
            : '콤마 ${results.length}대를 찾았어요. 연결할 기기를 골라 주세요.',
      );
      _notify();
    }
  }

  static String _sourceLabel(CandidateSource source) => switch (source) {
    CandidateSource.last => '마지막 주소',
    CandidateSource.known => '저장된 주소',
    CandidateSource.advertised => '콤마가 알린 주소',
    CandidateSource.router => '공유기·핫스팟 주소',
    CandidateSource.subnet => '네트워크 검색',
  };

  Future<ProbeResult> _probeOne(ProbeTarget candidate) async {
    totalProbes++;
    try {
      final result = await _probe.probe(candidate.host, candidate.port);
      if (result.outcome == ProbeOutcome.notKova) {
        final why = result.detail;
        _add(
          '${candidate.displayName} · 콤마가 아니에요${why == null ? '' : ' ($why)'}',
        );
      } else if (result.outcome == ProbeOutcome.kova) {
        _add('${candidate.displayName} · 콤마가 답했어요');
      } else if (result.outcome == ProbeOutcome.localOnly) {
        _add('${candidate.displayName} · $kovaLocalOnlyMessage');
        if (!localOnly.contains(candidate.displayName)) {
          localOnly = List.unmodifiable([...localOnly, candidate.displayName]);
        }
      } else if (result.refusing case final comma?) {
        if (!refused.contains(comma)) {
          refused = List.unmodifiable([...refused, comma]);
        }
        _add('${candidate.displayName} · 콤마가 이 휴대폰의 연결을 받지 않아요');
      }
      return result;
    } on Object {
      return const ProbeResult.noAnswer();
    }
  }

  Future<List<KovaDevice>> _scanParallel(
    List<ProbeTarget> targets,
    int generation, [
    List<KovaDevice> already = const [],
  ]) async {
    final results = <KovaDevice>[];
    var next = 0;
    var sinceNotify = 0;
    Future<void> worker() async {
      while (next < targets.length && generation == _generation) {
        final candidate = targets[next++];
        final result = await _probeOne(candidate);
        if (generation != _generation) return;
        probed++;
        if (result.device case final device?) {
          if (!results.contains(device)) results.add(device);
          found = List.unmodifiable([
            ...already,
            for (final d in results)
              if (!already.contains(d)) d,
          ]);
        }
        if (++sinceNotify >= 8 || next >= targets.length) {
          sinceNotify = 0;
          _notify();
        }
      }
    }

    final workers = concurrency.clamp(1, targets.isEmpty ? 1 : targets.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return results;
  }

  void _scheduleRetry(int generation) {
    if (generation != _generation || !_active) return;
    _failedPasses++;
    final delay = backoff[(_failedPasses - 1).clamp(0, backoff.length - 1)];
    nextRetry = delay;
    _phase = AutoConnectPhase.waiting;
    _add('${delay.inSeconds}초 뒤 다시 찾아요.');
    _notify();
    _retryTimer = Timer(delay, () {
      if (generation != _generation) return;
      _kick('다시 시도');
    });
  }

  Future<void> _connect(KovaDevice chosen, String how) async {
    device = chosen;
    problem = null;
    _failedPasses = 0;
    _heartbeatFailures = 0;
    nextRetry = null;
    if (!found.contains(chosen)) found = List.unmodifiable([...found, chosen]);
    _phase = AutoConnectPhase.connected;
    _add('콤마 ${chosen.displayName}에 연결했어요 ($how).');
    _notify();
    final generation = _generation;
    try {
      await target.attach(chosen, openTelemetry: !telemetryHeld);
    } on Object {
      _add('연결 준비 중 문제가 있었어요. 계속 확인해요.');
    }
    if (generation != _generation || !_active || device != chosen) return;
    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    if (!_active) return;
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_heartbeat());
    });
  }

  Future<void> _heartbeat({bool lossOnFirstFailure = false}) async {
    final current = device;
    if (!_active || current == null || _heartbeatRunning) return;
    _heartbeatRunning = true;
    final generation = _generation;
    ProbeResult result;
    try {
      totalProbes++;
      result = await _probe.probe(current.host, current.port);
    } on Object {
      result = const ProbeResult.noAnswer();
    } finally {
      _heartbeatRunning = false;
    }
    if (generation != _generation || device != current || !_active) return;
    final answered = result.device;
    if (result.outcome == ProbeOutcome.kova &&
        answered != null &&
        current.pin != null &&
        answered.pin != current.pin) {
      // Another certificate at the same address: not the comma we were
      // talking to. Look for it again.
      _add(
        '${current.displayName} · ${KovaLinkText.message(KovaLinkProblem.identityMismatch)}',
      );
      device = null;
      target.detach(current);
      _kick('다른 콤마가 답함', reset: true);
      return;
    }
    if (result.outcome == ProbeOutcome.kova) {
      if (_heartbeatFailures > 0) _add('콤마가 다시 응답해요.');
      _heartbeatFailures = 0;
      try {
        await target.keepAlive(current, openTelemetry: !telemetryHeld);
      } on Object {
        // Next heartbeat retries.
      }
      return;
    }
    _heartbeatFailures++;
    if (!lossOnFirstFailure &&
        _heartbeatFailures < heartbeatFailuresBeforeLost) {
      _add('콤마가 답이 없어요 ($_heartbeatFailures/$heartbeatFailuresBeforeLost).');
      _notify();
      return;
    }
    _add('콤마와 연결이 끊겼어요. 다시 찾아요.');
    device = null;
    target.detach(current);
    _kick('연결 끊김', reset: true);
  }

  void _startWatch() {
    _watchTimer?.cancel();
    if (!_active) return;
    _watchTimer = Timer.periodic(networkWatchInterval, (_) {
      unawaited(_watchNetworks());
    });
  }

  Future<void> _watchNetworks() async {
    if (!_active || _watchRunning) return;
    _watchRunning = true;
    List<LocalNetwork> nets;
    try {
      nets = await _listNetworks();
    } on Object {
      return;
    } finally {
      _watchRunning = false;
    }
    if (!_active) return;
    final signature = _signature(nets);
    final previous = _networkSignature;
    if (previous == null || signature == previous) {
      _networkSignature = signature;
      return;
    }
    _networkSignature = signature;
    networks = List.unmodifiable(nets);
    _add('네트워크가 바뀌었어요.');
    if (device != null) {
      unawaited(_heartbeat(lossOnFirstFailure: true));
    } else {
      _kick('네트워크 바뀜', reset: true);
    }
  }

  static String _signature(List<LocalNetwork> nets) =>
      (nets.where((n) => n.scannable).map((n) => n.signature).toList()..sort())
          .join(',');

  void _stopAll() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchTimer?.cancel();
    _watchTimer = null;
  }

  void _add(String message) {
    _log.add(AutoConnectLogEntry(_clock(), message));
    if (_log.length > maxLogEntries) {
      _log.removeRange(0, _log.length - maxLogEntries);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopAll();
    _probe.close();
    super.dispose();
  }
}
