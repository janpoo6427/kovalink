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
  String toString() => '${(atMs / 1000).toStringAsFixed(2)}초 $text';
}

/// How many frames the 3D engine was asked to draw while the GPU view was
/// being checked. Tells "the engine never drew" apart from "it drew, but
/// nothing reached the screen".
@immutable
class RendererFrames {
  const RendererFrames(this.count, this.windowMs);
  final int count;
  final int windowMs;

  String get describe {
    final secs = (windowMs / 1000).toStringAsFixed(1);
    return '$count장 ($secs초 동안)';
  }
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
    this.note,
    this.frames,
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

  /// Plain-language explanation of [reason] (해요체), shown first in
  /// 설정 → 진단.
  final String? note;

  /// Frames the 3D engine drew during the last check (null = unknown).
  final RendererFrames? frames;

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
    String? Function()? note,
    RendererFrames? Function()? frames,
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
    note: note != null ? note() : this.note,
    frames: frames != null ? frames() : this.frames,
  );

  bool get _saver => quality == '절약';

  /// One sentence for people: what the road view shows right now.
  String get headline => switch (state) {
    RendererState.checking =>
      reason == null ? '3D 화면을 켜고 있어요' : '3D 화면이 아직 안 나와요',
    RendererState.gpu => '3D 화면이 잘 나오고 있어요',
    RendererState.fallback => '3D 화면이 안 나와서 2D 도로로 바꿨어요',
    RendererState.software =>
      _saver ? '절약 화질이라 2D 도로로 그리고 있어요' : '이 기기에서는 2D 도로로 그리고 있어요',
  };

  /// Why, and what happens next, in plain words.
  String get explanation {
    final next = switch (state) {
      RendererState.checking =>
        reason == null
            ? '확인될 때까지 2D 도로를 밑에 함께 보여 드려요.'
            : '화질이 고품질이라 3D를 계속 켜 두고, 2D 도로를 밑에 함께 보여 드려요.',
      RendererState.gpu => '',
      RendererState.fallback =>
        '화질을 다시 고르면 3D를 다시 시도해요. 계속 안 되면 ‘진단 복사’를 눌러 '
            '내용을 보내 주세요.',
      RendererState.software => _saver ? '화질을 자동이나 고품질로 바꾸면 3D로 그려요.' : '',
    };
    return [?note, if (next.isNotEmpty) next].join(' ');
  }

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
      ..writeln('요약: $headline');
    if (explanation.isNotEmpty) b.writeln('설명: $explanation');
    b
      ..writeln('렌더러: ${rendererStateLabel(state)}')
      ..writeln('화질 설정: $quality')
      ..writeln('전환 이유: ${reason ?? '없음'}')
      ..writeln('텍스처: $textureSource (시도 ${attempt + 1})')
      ..writeln('화면 확인: $probe')
      ..writeln('3D 그림: ${frames?.describe ?? '-'}')
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

  /// [note] is the plain-language version of [reason] (null = none).
  void setState(RendererState state, {String? reason, String? note}) {
    if (value.state == state && value.reason == reason && value.note == note) {
      return;
    }
    value = value.copyWith(
      state: state,
      reason: () => reason,
      note: () => note,
    );
    log(
      '렌더러=${rendererStateLabel(state)}'
      '${reason == null ? '' : ' 이유=$reason'}',
    );
  }

  void setFrames(RendererFrames? frames) {
    value = value.copyWith(frames: () => frames);
    if (frames != null) log('3D 그림: ${frames.describe}');
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
