// Local service announcements (mDNS / DNS-SD) as one more place the Finder
// looks for a comma. An announcement only names an address: the comma at
// that address is still checked like any other (TLS, 401 challenge, pin).
import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:kovalink/src/network/device_discovery.dart';

/// Service type announced by kovapilot and listed in iOS's NSBonjourServices.
const kovaLinkServiceType = '_kovalink._tcp';

/// Where announced commas come from. Tests pass a fake.
abstract class CommaAdvertSource {
  /// Addresses announced within [timeout]. Never throws.
  Future<List<({String host, int port})>> lookup(Duration timeout);
  void close();
}

/// Android NSD / Apple Bonjour through the bonsoir plugin (MIT).
class BonsoirCommaAdvertSource implements CommaAdvertSource {
  BonsoirCommaAdvertSource({this.type = kovaLinkServiceType});

  final String type;
  bool _closed = false;

  @override
  Future<List<({String host, int port})>> lookup(Duration timeout) async {
    if (_closed) return const [];
    final found = <({String host, int port})>{};
    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? events;
    try {
      final d = discovery = BonsoirDiscovery(type: type, printLogs: false);
      await d.initialize().timeout(timeout);
      events = d.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            unawaited(
              Future(
                () => service.resolve(d.serviceResolver),
              ).catchError((_) {}),
            );
          case BonsoirDiscoveryServiceResolvedEvent(:final service):
            for (final address in service.hostAddresses) {
              final host = address.split('%').first;
              if (isPolicyTarget(host, service.port)) {
                found.add((host: host, port: service.port));
              }
            }
          default:
            break;
        }
      });
      await d.start().timeout(timeout);
      await Future<void>.delayed(timeout);
    } on Object {
      // No plugin (tests, desktop), no permission or no network: nothing.
    } finally {
      await events?.cancel();
      try {
        await discovery?.stop();
      } on Object {
        // Already stopped.
      }
    }
    return found.toList();
  }

  @override
  void close() => _closed = true;
}
