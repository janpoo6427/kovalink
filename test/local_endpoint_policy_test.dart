import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

void main() {
  test('allows local and private websocket endpoints', () {
    expect(
      LocalEndpointPolicy.validate('ws://comma.local:8082/v1/telemetry'),
      isNull,
    );
    expect(
      LocalEndpointPolicy.validate('wss://192.168.1.20/telemetry'),
      isNull,
    );
    expect(LocalEndpointPolicy.validate('ws://10.0.0.2:8080'), isNull);
  });

  test('rejects public endpoints and non-websocket schemes', () {
    expect(
      LocalEndpointPolicy.validate('wss://example.com/telemetry'),
      isNotNull,
    );
    expect(
      LocalEndpointPolicy.validate('https://comma.local/telemetry'),
      isNotNull,
    );
  });

  test('allows only local HTTP signaling endpoints', () {
    expect(
      LocalEndpointPolicy.validateSignaling(
        'http://comma.local:8082/v1/stream',
      ),
      isNull,
    );
    expect(
      LocalEndpointPolicy.validateSignaling('https://192.168.0.4/v1/stream'),
      isNull,
    );
    expect(
      LocalEndpointPolicy.validateSignaling('https://example.com/v1/stream'),
      isNotNull,
    );
    expect(
      LocalEndpointPolicy.validateSignaling('ws://comma.local/v1/stream'),
      isNotNull,
    );
  });

  test('rejects public domains that only look like private addresses', () {
    const hosts = [
      'fc2.com',
      'fdroid.org',
      'fcbarcelona.com',
      'fd.example.com',
      'fe80.example',
      '10.example.com',
      '192.168.evil.com',
      '172.16.evil.com',
      '127.0.0.1.nip.io',
      'localhost.evil.com',
      'comma.local.evil.com',
    ];
    for (final host in hosts) {
      _expectRejectedOnAllSchemes(host);
    }
  });

  test('allows IPv6 loopback, link-local and unique-local literals', () {
    const hosts = [
      '[::1]',
      '[fd00::1]',
      '[fc00::1]',
      '[fe80::1]',
      '[fe80::1%25usb0]',
      '[fe80:1::1]',
    ];
    for (final host in hosts) {
      _expectAllowedOnAllSchemes(host);
    }
  });

  test('rejects public and mapped IPv6 literals', () {
    const hosts = [
      '[2001:db8::1]',
      '[2606:4700:4700::1111]',
      '[::ffff:8.8.8.8]',
      '[::ffff:10.0.0.1]',
      '[fec0::1]',
      '[fc2::1]',
      '[febf::1]',
      '[fe81::1]',
    ];
    for (final host in hosts) {
      _expectRejectedOnAllSchemes(host);
    }
  });

  test('keeps private IPv4 and local hostnames allowed', () {
    const hosts = [
      '192.168.0.10',
      '10.0.0.2',
      '172.16.0.1',
      '172.31.255.254',
      '127.0.0.1',
      'comma.local',
      'localhost',
    ];
    for (final host in hosts) {
      _expectAllowedOnAllSchemes(host);
    }
  });

  test('rejects IPv4 addresses outside the private allowlist', () {
    const hosts = [
      '8.8.8.8',
      '11.0.0.1',
      '172.15.0.1',
      '172.32.0.1',
      '192.169.0.1',
    ];
    for (final host in hosts) {
      _expectRejectedOnAllSchemes(host);
    }
  });

  test('rejects non-canonical IPv4 forms that resolvers read differently', () {
    const hosts = ['010.0.0.1', '0127.0.0.1', '0xa.0.0.1', '+10.0.0.1'];
    for (final host in hosts) {
      _expectRejectedOnAllSchemes(host);
    }
  });
}

void _expectAllowedOnAllSchemes(String host) {
  for (final scheme in ['ws', 'wss']) {
    final url = '$scheme://$host:8082/v1/telemetry';
    expect(LocalEndpointPolicy.validate(url), isNull, reason: url);
  }
  for (final scheme in ['http', 'https']) {
    final url = '$scheme://$host:8082/v1/stream';
    expect(LocalEndpointPolicy.validateSignaling(url), isNull, reason: url);
  }
}

void _expectRejectedOnAllSchemes(String host) {
  for (final scheme in ['ws', 'wss']) {
    final url = '$scheme://$host:8082/v1/telemetry';
    expect(LocalEndpointPolicy.validate(url), isNotNull, reason: url);
  }
  for (final scheme in ['http', 'https']) {
    final url = '$scheme://$host:8082/v1/stream';
    expect(LocalEndpointPolicy.validateSignaling(url), isNotNull, reason: url);
  }
}
