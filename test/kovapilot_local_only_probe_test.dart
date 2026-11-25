// HttpDeviceProbe over a real loopback socket against the kovapilot
// gateway's 403 local_client_required answer. Plain `test`s only (a
// testWidgets in the same file would replace HttpClient with a fake).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/device_discovery.dart';

const _refusal =
    '{"error": {"code": "local_client_required", '
    '"message": "only loopback host names are supported"}}';

void main() {
  late HttpServer server;
  late HttpDeviceProbe probe;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    probe = HttpDeviceProbe();
  });

  tearDown(() async {
    probe.close();
    await server.close(force: true);
  });

  void answer(int status, String body) => server.listen((request) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(body)
      ..close();
  });

  test('403 local_client_required: found, not allowed yet', () async {
    answer(403, _refusal);
    final r = await probe.probe('127.0.0.1', server.port);
    expect(r.outcome, ProbeOutcome.localOnly);
    expect(r.device, isNull);
  });

  test('another 403 is still not a comma', () async {
    answer(403, '{"error": {"code": "forbidden", "message": "x"}}');
    final r = await probe.probe('127.0.0.1', server.port);
    expect(r.outcome, ProbeOutcome.notKova);
  });
}
