import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// What the road view is drawing right now.
enum RendererState {
  /// GPU view mounted, first frame not confirmed yet (software road shown
  /// underneath meanwhile).
  checking,

  /// GPU (Filament) frames confirmed on screen.
  gpu,

  /// GPU view failed or stayed blank; the software renderer took over.
  fallback,

  /// Software renderer by choice (절약) or because the platform has no GPU
  /// view.
  software,
}

String rendererStateLabel(RendererState state) => switch (state) {
  RendererState.checking => 'GPU 확인 중',
  RendererState.gpu => 'GPU',
  RendererState.fallback => '대체 화면(소프트웨어)',
  RendererState.software => '소프트웨어',
};

@immutable
class RendererEvent {
  const RendererEvent(this.atMs, this.text);
  final int atMs;
  final String text;

  @override
  String toString() => '${(atMs / 1000).toStringAsFixed(2)}s $text';
}

@immutable
class RendererReport {
  const RendererReport({
    this.state = RendererState.software,
    this.quality = '-',
    this.reason,
    this.textureSource = '-',
    this.attempt = 0,
    this.probe = '-',
    this.events = const [],
    this.device = const {},
    this.nativeLog = const [],
  });

  final RendererState state;

  /// 설정 → 화질 label.
  final String quality;

  /// Why the software renderer took over (null while the GPU is fine).
  final String? reason;

  /// Android texture path (SurfaceProducer / SurfaceTexture).
  final String textureSource;

  /// GPU view attempt number (0 = first).
  final int attempt;

  /// Last on-screen check of the GPU frame.
  final String probe;
  final List<RendererEvent> events;

  /// Device facts from the platform (model, Android version, GL renderer).
  final Map<String, String> device;

  /// Recent rendering-related lines from this app's own logcat.
  final List<String> nativeLog;

  RendererReport copyWith({
    RendererState? state,
    String? quality,
    String? Function()? reason,
    String? textureSource,
    int? attempt,
    String? probe,
    List<RendererEvent>? events,
    Map<String, String>? device,
    List<String>? nativeLog,
  }) => RendererReport(
    state: state ?? this.state,
    quality: quality ?? this.quality,
    reason: reason != null ? reason() : this.reason,
    textureSource: textureSource ?? this.textureSource,
    attempt: attempt ?? this.attempt,
    probe: probe ?? this.probe,
    events: events ?? this.events,
    device: device ?? this.device,
    nativeLog: nativeLog ?? this.nativeLog,
  );

  String get deviceLine {
    String d(String k) => device[k] ?? '?';
    if (device.isEmpty) return '기기 정보 없음';
    return '${d('manufacturer')} ${d('model')} · Android ${d('release')} '
        '(SDK ${d('sdk')})';
  }

  String get gpuLine {
    if (device.isEmpty) return 'GPU 정보 없음';
    final renderer = device['glRenderer'] ?? '?';
    final flutter = device['flutterBackend'] ?? '?';
    return '$renderer · Flutter $flutter · 3D Filament OpenGL ES';
  }

  /// Plain text for the copy button and logcat.
  String toText() {
    final b = StringBuffer()
      ..writeln('KovaLink 진단 (${RendererDiagnostics.build})')
      ..writeln('렌더러: ${rendererStateLabel(state)}')
      ..writeln('화질 설정: $quality')
      ..writeln('전환 이유: ${reason ?? '없음'}')
      ..writeln('텍스처: $textureSource (시도 ${attempt + 1})')
      ..writeln('화면 확인: $probe')
      ..writeln('기기: $deviceLine')
      ..writeln('GPU: $gpuLine');
    for (final key in device.keys.toList()..sort()) {
      b.writeln('  $key=${device[key]}');
    }
    b.writeln('기록:');
    for (final e in events) {
      b.writeln('  $e');
    }
    if (nativeLog.isNotEmpty) {
      b.writeln('logcat:');
      for (final line in nativeLog) {
        b.writeln('  $line');
      }
    }
    return b.toString();
  }
}

/// Renderer state shown in 설정 → 진단 and mirrored to logcat (tag
/// `kovalink`), so a single screenshot of that card explains a blank road.
///
/// Updates may come from widget lifecycles (initState, build); listeners are
/// then notified after the frame so no widget is dirtied mid-build.
class RendererDiagnostics extends ChangeNotifier
    implements ValueListenable<RendererReport> {
  RendererDiagnostics._();

  static final instance = RendererDiagnostics._();

  RendererReport _value = const RendererReport();
  bool _notifyScheduled = false;

  @override
  RendererReport get value => _value;

  set value(RendererReport next) {
    _value = next;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle ||
        binding.schedulerPhase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    binding.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// Platform side: android/app/src/main/kotlin/.../MainActivity.kt.
  static const channel = MethodChannel('io.kova.kovalink/diagnostics');

  /// Source commit passed with `--dart-define=KOVA_BUILD=<hash>`.
  static const build = String.fromEnvironment(
    'KOVA_BUILD',
    defaultValue: 'dev',
  );

  static const _maxEvents = 40;
  final _clock = Stopwatch()..start();
  bool _deviceRequested = false;

  /// Appends a timestamped line and writes it to logcat.
  void event(String text) {
    final events = [
      ...value.events,
      RendererEvent(_clock.elapsedMilliseconds, text),
    ];
    value = value.copyWith(
      events: events.length > _maxEvents
          ? events.sublist(events.length - _maxEvents)
          : events,
    );
    log(text);
  }

  void setState(RendererState state, {String? reason}) {
    if (value.state == state && value.reason == reason) return;
    value = value.copyWith(state: state, reason: () => reason);
    log(
      '렌더러=${rendererStateLabel(state)}'
      '${reason == null ? '' : ' 이유=$reason'}',
    );
  }

  void setQuality(String quality) {
    if (value.quality != quality) value = value.copyWith(quality: quality);
  }

  void setTexture(String source, int attempt) {
    if (value.textureSource == source && value.attempt == attempt) return;
    value = value.copyWith(textureSource: source, attempt: attempt);
  }

  void setProbe(String probe) {
    value = value.copyWith(probe: probe);
    log('화면 확인: $probe');
  }

  /// Asks the platform for device facts once (no-op off Android).
  Future<void> loadDevice() async {
    if (_deviceRequested) return;
    _deviceRequested = true;
    try {
      final info = await channel.invokeMapMethod<String, Object?>('deviceInfo');
      if (info == null) return;
      value = value.copyWith(
        device: {
          for (final e in info.entries)
            if (e.value != null) e.key: '${e.value}',
        },
      );
      log('기기: ${value.deviceLine} / GPU: ${value.gpuLine}');
    } catch (_) {
      // Desktop tests and platforms without the channel.
    }
  }

  /// Pulls recent rendering lines from this app's logcat (Android only).
  Future<void> refreshNativeLog() async {
    try {
      final lines = await channel.invokeListMethod<String>('recentLog');
      if (lines != null) value = value.copyWith(nativeLog: lines);
    } catch (_) {}
  }

  /// Writes [message] to logcat with tag `kovalink` (debugPrint elsewhere).
  static void log(String message) {
    if (kDebugMode) debugPrint('kovalink: $message');
    unawaited(
      channel.invokeMethod<void>('log', message).catchError((Object _) {}),
    );
  }

  /// Fresh report (tests and worker captures).
  void reset() {
    _deviceRequested = false;
    value = const RendererReport();
  }
}
