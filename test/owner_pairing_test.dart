// Owner pairing on automatic Wi-Fi (kovapilot master-jh owner pairing):
// the comma shows a code, the phone types it, gets the owner token once and
// sends it from then on. Real TLS fake Gateway on 127.0.0.x.
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/owner_pairing.dart';
import 'package:kovalink/src/network/tailscale_vpn.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_wifi_gateway.dart';

KovaDevice _local(FakeWifiGateway g, [String pin = pinDeviceA]) => KovaDevice(
  host: g.address,
  port: g.port,
  bindScope: 'wifi',
  secure: true,
  localNetwork: true,
  pin: fixturePin(pin),
);

void main() {
  late MemorySettingsStore store;
  late SettingsController settings;
  late MemoryCommaTokenStore tokens;
  late CommaLink link;
  final gateways = <FakeWifiGateway>[];

  CommaLink newLink() => CommaLink(
    settings: settings,
    tokens: tokens,
    timeout: const Duration(seconds: 3),
  );

  setUp(() {
    store = MemorySettingsStore();
    settings = SettingsController(store: store);
    tokens = MemoryCommaTokenStore();
    link = newLink();
  });

  tearDown(() async {
    link.dispose();
    settings.dispose();
    for (final g in gateways) {
      await g.close();
    }
    gateways.clear();
  });

  Future<FakeWifiGateway> start({String at = '127.0.0.2'}) async {
    final g = await FakeWifiGateway.start(address: at, localNetwork: true);
    gateways.add(g);
    return g;
  }

  test('automatic Wi-Fi opens without a token and offers pairing', () async {
    final g = await start();
    expect(await link.open(_local(g)), isNull);
    expect(link.isOwner, isFalse);
    expect(link.session!.authorization, isEmpty);
    expect(link.health!.ownerPairing, isTrue);
    expect(link.health!.owner, isFalse);
    expect(TailscaleVpnClient(link).canManage, isFalse);
  });

  test('the code from the comma screen makes this phone the owner', () async {
    final g = await start();
    await link.open(_local(g));
    expect(await link.requestOwnerCode(), isA<OwnerCodeShown>());
    expect(g.pairRequests, 1);

    final wrong = await link.confirmOwnerCode('000000');
    expect(wrong, isA<OwnerCodeWrong>());
    expect((wrong as OwnerCodeWrong).remaining, 4);
    expect(tokens.tokens, isEmpty);
    expect(link.isOwner, isFalse);

    expect(await link.confirmOwnerCode(g.pairCode), isA<OwnerCodeAccepted>());
    expect(tokens.tokens.values.single, g.issuedToken);
    expect(settings.value.registeredComma!.pin, fixturePin(pinDeviceA));
    expect(settings.value.registeredComma!.host, g.address);
    expect(link.isOwner, isTrue);
    expect(link.session!.localNetworkPin, fixturePin(pinDeviceA));
    expect(link.session!.wifiAuthentication, 'localNetwork');
    expect(link.health!.owner, isTrue);
    expect(g.requests.last.authorization, 'Bearer ${g.issuedToken}');

    final vpn = TailscaleVpnClient(link);
    expect(vpn.canManage, isTrue);
    expect((await vpn.manage(VpnAction.status))['state'], 'needsLogin');
  });

  test(
    'after a restart the owner session opens with the saved token',
    () async {
      final g = await start();
      await link.open(_local(g));
      await link.requestOwnerCode();
      await link.confirmOwnerCode(g.pairCode);
      link.dispose();

      link = newLink();
      expect(await link.open(_local(g)), isNull);
      expect(link.isOwner, isTrue);
      expect(link.ownerRejected, isFalse);
      expect(g.requests.last.authorization, 'Bearer ${g.issuedToken}');
    },
  );

  test(
    'another phone paired since: connects without the token and says so',
    () async {
      final g = await start();
      await link.open(_local(g));
      await link.requestOwnerCode();
      await link.confirmOwnerCode(g.pairCode);
      link.dispose();
      g.ownerToken = 'aa' * 32;

      link = newLink();
      expect(await link.open(_local(g)), isNull);
      expect(link.isOwner, isFalse);
      expect(link.ownerRejected, isTrue);
      expect(link.session!.authorization, isEmpty);
      // The next auto-connect pass keeps that session instead of retrying.
      final before = g.requestCount;
      expect(await link.open(_local(g)), isNull);
      expect(g.requestCount, before);
    },
  );

  test(
    'pairing is refused with the vehicle on or on an older kovapilot',
    () async {
      final g = await start();
      await link.open(_local(g));
      g.offroad = false;
      final refused = await link.requestOwnerCode();
      expect((refused as OwnerCodeRefused).message, OwnerPairingText.offroad);

      final old = await start(at: '127.0.0.3');
      old.ownerPairingSupported = false;
      final other = newLink();
      addTearDown(other.dispose);
      expect(await other.open(_local(old)), isNull);
      expect(other.health!.ownerPairing, isNull);
      expect(
        ((await other.requestOwnerCode()) as OwnerCodeRefused).message,
        OwnerPairingText.unsupported,
      );
    },
  );
}
