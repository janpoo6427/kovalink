// The comma's identity pin: SHA-256 of the certificate's public key. The
// expected values come from kovaPinCommand (openssl + sha256sum) run on the
// fixture files, so the app and the administrator's command agree.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/gateway_pin.dart';

import 'support/fake_wifi_gateway.dart';

void main() {
  group('pin from a PEM file', () {
    test('server.pem gives the same pin as the openssl command', () {
      final result = pinFromPem(fixtureText('device_a.pem'));
      expect(result, isA<PemPinFound>());
      final found = result as PemPinFound;
      expect(found.pin.hex, pinDeviceA);
      expect(found.fromCertificate, isTrue);
      expect(found.pin.asBase64, pinDeviceAB64);
      expect(
        (pinFromPem(fixtureText('device_b.pem')) as PemPinFound).pin.hex,
        pinDeviceB,
      );
    });

    test('a chain file pins its first certificate (the comma\'s own)', () {
      final found = pinFromPem(fixtureText('chain.pem')) as PemPinFound;
      expect(found.pin.hex, pinChainLeaf);
      expect(found.pin.hex, isNot(pinTestCa));
    });

    test('a PUBLIC KEY block gives the same pin', () {
      final found = pinFromPem(fixtureText('device_a.pub.pem')) as PemPinFound;
      expect(found.pin.hex, pinDeviceA);
      expect(found.fromCertificate, isFalse);
    });

    test('a private key is refused and not kept', () {
      final result = pinFromPem(fixtureText('device_a.key'));
      expect(result, isA<PemPinRefused>());
      expect((result as PemPinRefused).reason, PemPinText.privateKey);
    });

    test('anything else is refused', () {
      expect(
        (pinFromPem('hello') as PemPinRefused).reason,
        PemPinText.noCertificate,
      );
      expect(
        (pinFromPem(
                  '-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----',
                )
                as PemPinRefused)
            .reason,
        PemPinText.unreadable,
      );
    });

    test('a broken certificate never yields a pin', () {
      final pem = fixtureText('device_a.pem');
      final body = pem.split('\n').where((l) => !l.startsWith('-----')).join();
      final der = base64Decode(body);
      expect(GatewayPin.ofCertificateDer(der)?.hex, pinDeviceA);
      for (final cut in [0, 1, 10, 100, der.length - 1]) {
        expect(
          GatewayPin.ofCertificateDer(der.sublist(0, cut)),
          isNull,
          reason: 'cut at $cut',
        );
      }
    });
  });

  group('pasted pin', () {
    test('hex in the forms people paste', () {
      final upper = pinDeviceA.toUpperCase();
      final colons = [
        for (var i = 0; i < 64; i += 2) pinDeviceA.substring(i, i + 2),
      ].join(':');
      for (final text in [
        pinDeviceA,
        '  $pinDeviceA  ',
        upper,
        colons,
        '$pinDeviceA  -',
        'SHA2-256(stdin)= $pinDeviceA',
        '(stdin)= $pinDeviceA',
      ]) {
        expect(GatewayPin.tryParse(text)?.hex, pinDeviceA, reason: text);
      }
    });

    test('base64, with or without sha256/', () {
      expect(GatewayPin.tryParse(pinDeviceAB64)?.hex, pinDeviceA);
      expect(GatewayPin.tryParse('sha256/$pinDeviceAB64')?.hex, pinDeviceA);
      final unpadded = pinDeviceAB64.replaceAll('=', '');
      expect(GatewayPin.tryParse(unpadded)?.hex, pinDeviceA);
    });

    test('wrong lengths and garbage are refused', () {
      for (final text in [
        '',
        'abc',
        pinDeviceA.substring(1),
        '${pinDeviceA}00',
        '$pinDeviceA $pinDeviceB',
        'zz${pinDeviceA.substring(2)}',
        base64Encode(List.filled(31, 1)),
      ]) {
        expect(GatewayPin.tryParse(text), isNull, reason: text);
      }
    });

    test('shown grouped and short, compared in constant time', () {
      final pin = fixturePin(pinDeviceA);
      expect(pin.grouped.split(' '), hasLength(16));
      expect(pin.grouped.replaceAll(' ', ''), pinDeviceA);
      expect(pin.short, '298c ab76 … eff0');
      expect(pin.matches(fixturePin(pinDeviceA)), isTrue);
      expect(pin.matches(fixturePin(pinDeviceB)), isFalse);
      expect(pin.matches(null), isFalse);
      expect(pin, fixturePin(pinDeviceA));
      expect(GatewayPin.fromHex(pinDeviceA.toUpperCase()), isNull);
    });

    test('the administrator command reads server.pem under /persist', () {
      expect(kovaPinCommand, contains('/persist/kova/gateway/server.pem'));
      expect(kovaPinCommand, contains('sha256sum'));
      expect(kovaPinCommand, isNot(contains('server.key')));
    });
  });
}
