// Registering a comma and connecting to it again: nothing is saved until
// the comma showed the pasted certificate and accepted the token; the
// token lives only in the token store; the same comma is recognized at a
// new IP by its pin. Real TLS servers on 127.0.0.2/127.0.0.3.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_wifi_gateway.dart';

KovaDevice _seen(FakeWifiGateway g, [String pin = pinDeviceA]) => KovaDevice(
  host: g.address,
  port: g.port,
  secure: true,
  pin: fixturePin(pin),
);

void main() {
  late MemorySettingsStore store;
  late SettingsController settings;
  late MemoryCommaTokenStore tokens;
  late CommaLink link;
  final gateways = <FakeWifiGateway>[];

  setUp(() {
    store = MemorySettingsStore();
    settings = SettingsController(store: store);
    tokens = MemoryCommaTokenStore();
    link = CommaLink(
      settings: settings,
      tokens: tokens,
      timeout: const Duration(seconds: 3),
    );
  });

  tearDown(() async {
    link.dispose();
    settings.dispose();
    for (final g in gateways) {
      await g.close();
    }
    gateways.clear();
  });

  Future<FakeWifiGateway> start({
    String cert = 'device_a',
    String at = '127.0.0.2',
    int port = 0,
  }) async {
    final g = await FakeWifiGateway.start(cert: cert, address: at, port: port);
    gateways.add(g);
    return g;
  }

  test('a wrong token: refused, nothing saved', () async {
    final g = await start();
    final problem = await link.register(
      host: g.address,
      port: g.port,
      pin: fixturePin(pinDeviceA),
      token: 'ee' * 32,
    );
    expect(problem, KovaLinkProblem.tokenRejected);
    expect(tokens.tokens, isEmpty);
    expect(settings.value.registeredComma, isNull);
    expect(link.session, isNull);
    expect(g.requests.single.authorization, 'Bearer ${'ee' * 32}');
  });

  test('another certificate: refused before the token is sent', () async {
    final g = await start(cert: 'device_b');
    final problem = await link.register(
      host: g.address,
      port: g.port,
      pin: fixturePin(pinDeviceA),
      token: testToken,
    );
    expect(problem, KovaLinkProblem.identityMismatch);
    expect(g.requestCount, 0);
    expect(tokens.tokens, isEmpty);
    expect(settings.value.registeredComma, isNull);
  });

  test('another version is reported as such', () async {
    final g = await start()
      ..schemaVersion = 2;
    expect(
      await link.register(
        host: g.address,
        port: g.port,
        pin: fixturePin(pinDeviceA),
        token: testToken,
      ),
      KovaLinkProblem.versionMismatch,
    );
  });

  test(
    'registered: token in the store only, pin and address in settings',
    () async {
      final g = await start();
      expect(
        await link.register(
          host: g.address,
          port: g.port,
          pin: fixturePin(pinDeviceA),
          token: testToken,
        ),
        isNull,
      );
      expect(tokens.tokens, {pinDeviceA: testToken});
      final comma = settings.value.registeredComma!;
      expect(comma.pin.hex, pinDeviceA);
      expect(comma.host, '127.0.0.2');
      expect(link.session!.sendsToken, isTrue);
      await Future<void>.delayed(Duration.zero);
      final saved = jsonEncode(store.data);
      expect(saved, contains(pinDeviceA));
      expect(saved, isNot(contains(testToken)));
      final restored = AppSettings.fromJson(store.data!);
      expect(restored.registeredComma, comma);
      expect(link.canAttach(_seen(g)), isTrue);
      expect(link.canAttach(_seen(g, pinDeviceB)), isFalse);
      expect(
        link.canAttach(const KovaDevice(host: '127.0.0.1', port: 18082)),
        isTrue,
        reason: 'loopback development gateway',
      );
    },
  );

  test(
    'the same comma at a new IP is opened and its address updated',
    () async {
      final first = await start();
      await link.register(
        host: first.address,
        port: first.port,
        pin: fixturePin(pinDeviceA),
        token: testToken,
      );
      final moved = await start(at: '127.0.0.3');
      final device = _seen(moved);
      expect(link.canAttach(device), isTrue);
      expect(await link.open(device), isNull);
      expect(link.session!.endpoints.host, '127.0.0.3');
      await Future<void>.delayed(Duration.zero);
      expect(settings.value.registeredComma!.host, '127.0.0.3');
      expect(settings.value.registeredComma!.port, moved.port);
      expect(moved.requests.single.authorization, 'Bearer $testToken');
    },
  );

  test('a comma that is not the registered one is not opened', () async {
    final a = await start();
    await link.register(
      host: a.address,
      port: a.port,
      pin: fixturePin(pinDeviceA),
      token: testToken,
    );
    final b = await start(cert: 'device_b', at: '127.0.0.3');
    expect(
      await link.open(_seen(b, pinDeviceB)),
      KovaLinkProblem.needsRegistration,
    );
    expect(b.requestCount, 0);
    // Even if a found device claimed the registered pin, the connection
    // itself checks the certificate: nothing reaches b.
    expect(await link.open(_seen(b)), KovaLinkProblem.identityMismatch);
    expect(b.requestCount, 0);
  });

  test('a lost token asks to register again; forget clears both', () async {
    final g = await start();
    await link.register(
      host: g.address,
      port: g.port,
      pin: fixturePin(pinDeviceA),
      token: testToken,
    );
    tokens.tokens.clear();
    link.dispose();
    link = CommaLink(settings: settings, tokens: tokens);
    expect(await link.open(_seen(g)), KovaLinkProblem.needsToken);
    await tokens.write(fixturePin(pinDeviceA), testToken);
    expect(await link.open(_seen(g)), isNull);
    await link.forget();
    expect(tokens.tokens, isEmpty);
    expect(settings.value.registeredComma, isNull);
    expect(link.session, isNull);
  });

  test('every problem has a short line and a folded detail without jargon', () {
    for (final problem in KovaLinkProblem.values) {
      final words =
          '${KovaLinkText.message(problem)} ${KovaLinkText.detail(problem)}';
      for (final jargon in [
        'gateway',
        'Gateway',
        'HTTP',
        'SPKI',
        '/24',
        'TLS',
        'Bearer',
      ]) {
        expect(words, isNot(contains(jargon)), reason: '$problem: $jargon');
      }
      expect(KovaLinkText.message(problem), endsWith('요.'));
    }
  });
}
