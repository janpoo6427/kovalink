import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';

/// Answers from a table; records every probe and any probe outside the
/// local-only endpoint policy.
class FakeProbe implements DeviceProbe {
  final Map<String, ProbeResult> answers = {};
  final List<String> calls = [];
  final List<String> violations = [];
  Duration delay = Duration.zero;
  int inFlight = 0;
  int maxInFlight = 0;
  bool closed = false;

  void device(String host, [int port = 8082]) => answers['$host:$port'] =
      ProbeResult.kova(KovaDevice(host: host, port: port));

  void other(String host, [int port = 8082]) =>
      answers['$host:$port'] = const ProbeResult.notKova(null);

  void gone(String host, [int port = 8082]) => answers.remove('$host:$port');

  @override
  Future<ProbeResult> probe(String host, int port) async {
    if (!isPolicyTarget(host, port)) violations.add('$host:$port');
    calls.add('$host:$port');
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    inFlight--;
    return answers['$host:$port'] ?? const ProbeResult.noAnswer();
  }

  @override
  void close() => closed = true;
}

class FakeTarget implements AutoConnectTarget {
  bool live = false;
  final attached = <KovaDevice>[];
  final kept = <KovaDevice>[];
  final detached = <KovaDevice>[];

  /// `openTelemetry` of every attach / keepAlive call.
  final attachedTelemetry = <bool>[];
  final keptTelemetry = <bool>[];

  @override
  bool get isTelemetryLive => live;

  @override
  Future<void> attach(KovaDevice device, {bool openTelemetry = true}) async {
    attached.add(device);
    attachedTelemetry.add(openTelemetry);
  }

  @override
  Future<void> keepAlive(KovaDevice device, {bool openTelemetry = true}) async {
    kept.add(device);
    keptTelemetry.add(openTelemetry);
  }

  @override
  void detach(KovaDevice device) => detached.add(device);
}
