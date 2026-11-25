// Keeps looking for the kovapilot device (comma) until it answers, and
// watches it afterwards. KovaLink does little without the car, so this runs
// whenever the app is in the foreground and 자동 연결 is on.
//
// One search pass: last successful address → saved/known addresses and each
// network's `.1` router → the rest of every Wi-Fi/hotspot /24 in parallel.
// A host counts only after `/v1/health` answers like a kovapilot gateway.
// Failed passes wait 1 → 2 → 5 → 10 → 15 s (cap). Nothing runs while the app
// is in the background or the screen is off.
import 'dart:async';

import 'package:flutter/foundation.dart';
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

  /// A device is connected (found here, or connected by hand).
  connected,
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
  /// True while the telemetry socket is live (from any source).
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
    List<int> ports = const [kovaGatewayDefaultPort],
    List<int> Function()? portsProvider,
    this.concurrency = 24,
    this.backoff = defaultBackoff,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.networkWatchInterval = const Duration(seconds: 4),
    this.heartbeatFailuresBeforeLost = 2,
    this.maxLogEntries = 80,
    DateTime Function()? clock,
  }) : _probe = probe ?? HttpDeviceProbe(),
       _listNetworks = listNetworks ?? listLocalNetworks,
       _ports = portsProvider ?? (() => ports),
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

  /// The device being watched; null when connected by hand or not connected.
  KovaDevice? device;

  /// Connected by hand (telemetry live without a device found here).
  bool manual = false;

  /// The user left live telemetry on purpose (데모 보기). The comma is still
  /// found and watched and its settings stay open, but telemetry is not
  /// reopened behind the user's back until 지금 찾기, a manual connection or
  /// turning 자동 연결 off and on.
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
    AutoConnectPhase.waiting => '콤마 없음 · ${nextRetry?.inSeconds ?? 0}초 뒤 다시',
    AutoConnectPhase.choosing => '콤마 ${found.length}대 찾음',
    AutoConnectPhase.connected => '콤마 연결됨',
  };

  // ---- inputs ----------------------------------------------------------

  void setEnabled(bool on) {
    if (_disposed || on == _enabled) return;
    _enabled = on;
    if (!on) {
      _stopAll();
      device = null;
      manual = false;
      found = const [];
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
    manual = false;
    telemetryHeld = false;
    _kick('직접 다시 찾기', reset: true);
  }

  /// The user picked one of several devices.
  Future<void> choose(KovaDevice chosen) async {
    if (!_active) return;
    _generation++;
    _retryTimer?.cancel();
    await _connect(chosen, '직접 고름');
  }

  /// The telemetry socket dropped. Check the device right away; search again
  /// if it is gone (or if the connection was made by hand).
  void connectionLost() {
    if (!_active) return;
    if (device != null) {
      _add('주행 정보 연결이 끊겼어요. 콤마를 확인해요.');
      unawaited(_heartbeat(lossOnFirstFailure: true));
    } else if (manual || _phase == AutoConnectPhase.connected) {
      manual = false;
      _add('연결이 끊겼어요. 다시 찾아요.');
      _kick('연결 끊김', reset: true);
    }
  }

  /// The user left live telemetry on purpose (데모 보기): keep the found comma
  /// but do not reopen telemetry until the user asks again.
  void telemetryLeftByUser() {
    if (!_active) return;
    telemetryHeld = true;
    _add('데모를 보는 동안에는 주행 정보를 다시 잇지 않아요.');
    if (device == null && (manual || _phase == AutoConnectPhase.connected)) {
      manual = false;
      _kick('데모 보기', reset: true);
      return;
    }
    _notify();
  }

  /// Telemetry went live (e.g. 연결 pressed with a typed address).
  void telemetryConnected() {
    telemetryHeld = false;
    if (!_active || device != null) return;
    _generation++;
    _retryTimer?.cancel();
    manual = true;
    found = const [];
    _phase = AutoConnectPhase.connected;
    _add('입력한 주소로 연결됐어요. 찾기를 멈춰요.');
    _notify();
  }

  // ---- loop ------------------------------------------------------------

  void _resume(String reason) {
    _startWatch();
    if (target.isTelemetryLive && device == null) {
      telemetryConnected();
      return;
    }
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
    scanningSubnets = const [];
    _add('$attempt번째 찾기 시작 ($reason)');
    _notify();

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

    for (final candidate in plan.priority) {
      final result = await _probeOne(candidate);
      if (generation != _generation) return;
      probed++;
      if (result.device case final device?) {
        await _connect(device, _sourceLabel(candidate.source));
        return;
      }
      if (candidate.source == CandidateSource.last) {
        _add('마지막 주소 ${candidate.displayName} · 답이 없어요');
      }
      _notify();
    }

    if (plan.scan.isNotEmpty) {
      _add('${scanningSubnets.join(', ')}에서 ${plan.scan.length}곳을 찾아봐요.');
      _notify();
    }
    final results = await _scanParallel(plan.scan, generation);
    if (generation != _generation) return;

    if (results.isEmpty) {
      _add('콤마를 찾지 못했어요.');
      _scheduleRetry(generation);
    } else if (results.length == 1) {
      await _connect(results.single, '네트워크 검색');
    } else {
      found = List.unmodifiable(results);
      _phase = AutoConnectPhase.choosing;
      _add('콤마 ${results.length}대를 찾았어요. 연결할 기기를 골라 주세요.');
      _notify();
    }
  }

  static String _sourceLabel(CandidateSource source) => switch (source) {
    CandidateSource.last => '마지막 주소',
    CandidateSource.known => '저장된 주소',
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
      }
      return result;
    } on Object {
      return const ProbeResult.noAnswer();
    }
  }

  Future<List<KovaDevice>> _scanParallel(
    List<ProbeTarget> targets,
    int generation,
  ) async {
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
          found = List.unmodifiable(results);
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
    manual = false;
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
    } else if (!manual) {
      _kick('네트워크 바뀜', reset: true);
    } else {
      _notify();
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
