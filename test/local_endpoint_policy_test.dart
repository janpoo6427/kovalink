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
}
