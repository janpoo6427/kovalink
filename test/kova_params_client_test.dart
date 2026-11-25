import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';

import 'support/fake_kova_gateway.dart';

/// Real HTTP on 127.0.0.1 so the dart:io transport is exercised end to end.
class _HttpFake {
  _HttpFake(this.server, this.gateway);

  final HttpServer server;
  final FakeKovaGateway gateway;
  Duration delay = Duration.zero;
  String? rawBody;
  int? rawStatus;

  String get origin => 'http://127.0.0.1:${server.port}';

  static Future<_HttpFake> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _HttpFake(server, FakeKovaGateway());
    server.listen(fake._handle);
    return fake;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await _respond(request);
    } on Object {
      // The client may have aborted (timeout tests).
    }
  }

  Future<void> _respond(HttpRequest request) async {
    await Future<void>.delayed(delay);
    final KovaHttpResponse response;
    if (rawBody != null) {
      response = KovaHttpResponse(rawStatus ?? 200, rawBody!);
    } else if (request.method == 'POST') {
      final body = await utf8.decodeStream(request);
      response = await gateway.postJson(request.uri, body, Duration.zero);
    } else {
      response = await gateway.get(request.uri, Duration.zero);
    }
    request.response
      ..statusCode = response.statusCode
      ..headers.contentType = ContentType.json
      ..write(response.body);
    await request.response.close();
  }
}

void main() {
  late _HttpFake fake;
  late KovaParamsClient client;

  setUp(() async {
    fake = await _HttpFake.start();
    client = KovaParamsClient.tryCreate(
      fake.origin,
      timeout: const Duration(milliseconds: 600),
    )!;
  });

  tearDown(() async {
    client.close();
    await fake.server.close(force: true);
  });

  test('reads health and the catalog over HTTP', () async {
    final health = await client.health();
    expect(health.status, 'ok');
    expect(health.bindScope, 'loopback');
    final doc = await client.fetch();
    expect(doc.revision, 0);
    expect(doc.setting('steering.always_on')!.title.resolve(), '항시 조향');
  });

  test('update maps 200 / 409 / 403 / 400 to distinct outcomes', () async {
    final applied = await client.update('e2e.level', 4, 0);
    expect(applied, isA<KovaUpdateApplied>());
    expect((applied as KovaUpdateApplied).document.revision, 1);
    expect(applied.document.setting('e2e.level')!.value, 4);

    expect(await client.update('e2e.level', 5, 0), isA<KovaUpdateConflict>());

    fake.gateway.offroad = false;
    final onroad = await client.update('steering.always_on', true, 1);
    expect(onroad, isA<KovaUpdateRejected>());
    expect((onroad as KovaUpdateRejected).code, 'update_forbidden');
    expect(onroad.reason, contains('시동을 끈 뒤'));

    final range = await client.update('e2e.level', 99, 1) as KovaUpdateRejected;
    expect(range.code, 'invalid_value');
    expect(range.reason, contains('범위'));
    final unknown = await client.update('e2e.nope', 1, 1) as KovaUpdateRejected;
    expect(unknown.reason, contains('모르는 항목'));
    final readOnly =
        await client.update('e2e.build_label', 'x', 1) as KovaUpdateRejected;
    expect(readOnly.statusCode, 403);
    expect(readOnly.reason, contains('읽기 전용'));
    // The raw gateway message is never shown.
    expect(readOnly.reason, isNot(contains('e2e.build_label')));
  });

  test('a slow gateway is a timeout, never a success', () async {
    fake.delay = const Duration(seconds: 2);
    expect(await client.update('e2e.level', 4, 0), isA<KovaUpdateTimedOut>());
    await expectLater(
      client.fetch(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.timeout,
        ),
      ),
    );
  });

  test('non-JSON and unknown errors are failures, not successes', () async {
    fake.rawBody = '<html>proxy</html>';
    expect(await client.update('e2e.level', 4, 0), isA<KovaUpdateFailed>());
    await expectLater(
      client.fetch(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.format,
        ),
      ),
    );
    fake.rawBody = jsonEncode({
      'schemaVersion': 3,
      'revision': 0,
      'groups': [],
      'settings': [],
    });
    await expectLater(
      client.fetch(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.schema,
        ),
      ),
    );
    fake.rawStatus = 503;
    fake.rawBody = jsonEncode({
      'error': {
        'code': 'kova_params_unavailable',
        'message': 'stored settings failed validation',
      },
    });
    await expectLater(
      client.fetch(),
      throwsA(
        isA<KovaParamsException>().having((e) => e.statusCode, 'status', 503),
      ),
    );
  });

  test('a stopped gateway is a transport failure', () async {
    await fake.server.close(force: true);
    expect(await client.update('e2e.level', 4, 0), isA<KovaUpdateFailed>());
    await expectLater(
      client.health(),
      throwsA(
        isA<KovaParamsException>().having(
          (e) => e.kind,
          'kind',
          KovaFailureKind.transport,
        ),
      ),
    );
  });

  test(
    'public, path-bearing and non-HTTP addresses are refused before any request',
    () {
      final errors = <String>[];
      for (final address in [
        'http://example.com:8082',
        'https://8.8.8.8',
        'ws://127.0.0.1:8082',
        'http://127.0.0.1:8082/v1/kova-params',
        'http://user@127.0.0.1:8082',
        'http://comma.local:8082?x=1',
      ]) {
        expect(
          KovaParamsClient.tryCreate(address, onError: errors.add),
          isNull,
          reason: address,
        );
      }
      expect(errors, hasLength(6));
      expect(errors.first, contains('같은 네트워크'));
      final ok = KovaParamsClient.tryCreate('http://comma.local:8082/')!;
      expect(ok.baseUri.toString(), 'http://comma.local:8082');
      ok.close();
    },
  );
}
