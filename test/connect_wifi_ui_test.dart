// Connection screen pieces for Wi-Fi: IP로 연결 (input checks, outcomes),
// 콤마 등록 (token hidden, pin pasted or from server.pem, nothing saved
// until the comma agrees), the registered comma card and the error lines.
// Network replaced by fakes (widget tests cannot open sockets).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/features/connect/comma_register_page.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/kova_params/kova_params_client.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/settings/app_settings.dart';

import 'support/fake_auto_connect.dart';
import 'support/fake_wifi_gateway.dart';

/// Answers /v1/health like a comma with [pin] and [token]: another pin
/// fails like the pinned client does (nothing sent), another token is 401.
class _CommaHealth implements KovaParamsTransport {
  _CommaHealth(this.credentials);
  final GatewayCredentials? credentials;
  static const pin = pinDeviceA;
  static const token = testToken;
  static final sent = <String>[];

  @override
  Future<KovaHttpResponse> get(Uri uri, Duration timeout) async {
    final c = credentials!;
    if (c.pin.hex != pin) throw GatewayIdentityMismatch(fixturePin(pin));
    sent.add(c.token);
    if (c.token != token) {
      return const KovaHttpResponse(
        401,
        '{"error": {"code": "authentication_required", "message": "x"}}',
      );
    }
    return const KovaHttpResponse(
      200,
      '{"status": "ok", "schemaVersion": 1, "bindScope": "wifi", "authentication": "bearer"}',
    );
  }

  @override
  Future<KovaHttpResponse> postJson(Uri uri, String body, Duration timeout) =>
      get(uri, timeout);

  @override
  void close() {}
}

KovaDevice _comma(String host, [String pin = pinDeviceA]) =>
    KovaDevice(host: host, port: 8082, secure: true, pin: fixturePin(pin));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late SettingsController settings;
  late MemoryCommaTokenStore tokens;
  late CommaLink link;
  late FakeProbe probe;
  late FakeTarget target;
  late AutoConnectController auto;
  late GatewayController gateway;
  Uint8List? picked;

  setUp(() {
    _CommaHealth.sent.clear();
    settings = SettingsController(store: MemorySettingsStore());
    tokens = MemoryCommaTokenStore();
    link = CommaLink(
      settings: settings,
      tokens: tokens,
      sessionFactory: (endpoints, credentials) => GatewaySession.withTransport(
        _CommaHealth(credentials),
        endpoints: endpoints,
        credentials: credentials,
      ),
    );
    probe = FakeProbe();
    target = FakeTarget();
    auto = AutoConnectController(
      target: target,
      probe: probe,
      listNetworks: () async => [LocalNetwork.named('wlan0', '192.168.43.5')],
      canAttach: link.canAttach,
    );
    gateway = GatewayController();
    picked = null;
  });

  tearDown(() {
    auto.dispose();
    gateway.dispose();
    link.dispose();
    settings.dispose();
  });

  Future<void> pumpConnect(
    WidgetTester tester, {
    Size size = const Size(420, 1800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectScreen(
            controller: gateway,
            settings: settings,
            autoConnect: auto,
            link: link,
            pemPicker: () async => picked,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpRegister(WidgetTester tester, {KovaDevice? device}) async {
    tester.view.physicalSize = const Size(420, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommaRegisterPage(
            link: link,
            device: device,
            pemPicker: () async => picked,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openIpSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('connect-by-ip')).first);
    await _settle(tester);
    expect(find.byKey(const ValueKey('ip-connect-sheet')), findsOneWidget);
  }

  Future<void> submitIp(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('ip-input')), text);
    await tester.tap(find.byKey(const ValueKey('ip-connect')));
    await _settle(tester);
  }

  group('IP로 연결', () {
    testWidgets(
      'public IPs and bad ports are refused before anything is sent',
      (tester) async {
        await pumpConnect(tester);
        await openIpSheet(tester);
        expect(find.byKey(const ValueKey('ip-help')), findsOneWidget);
        expect(find.textContaining('네트워크 → 고급'), findsOneWidget);
        await submitIp(tester, '8.8.8.8');
        expect(find.text(CommaAddressText.notLocal), findsOneWidget);
        await submitIp(tester, '192.168.43.20:99999');
        expect(find.text(CommaAddressText.port), findsOneWidget);
        await submitIp(tester, 'comma');
        expect(find.text(CommaAddressText.format), findsOneWidget);
        expect(probe.calls, isEmpty);
      },
    );

    testWidgets('nothing there, silent, refusing: one plain line each', (
      tester,
    ) async {
      await pumpConnect(tester);
      await openIpSheet(tester);
      await submitIp(tester, '192.168.43.20');
      expect(probe.calls, ['192.168.43.20:8082']);
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.notKova)),
        findsOneWidget,
      );

      probe.answers['192.168.43.21:9000'] = const ProbeResult.notKova(
        ProbeResult.silentDetail,
      );
      await submitIp(tester, '192.168.43.21:9000');
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.noAnswer)),
        findsOneWidget,
      );

      probe.answers['192.168.43.22:8082'] = ProbeResult.refused(
        _comma('192.168.43.22'),
      );
      await submitIp(tester, '192.168.43.22');
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.notAllowed)),
        findsOneWidget,
      );
      for (final word in ['gateway', 'HTTP', 'SPKI', '/24', 'Bearer']) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
    });

    testWidgets('a new comma opens registration with its address', (
      tester,
    ) async {
      probe.answers['192.168.43.20:8082'] = ProbeResult.kova(
        _comma('192.168.43.20'),
      );
      await pumpConnect(tester);
      await openIpSheet(tester);
      await submitIp(tester, '192.168.43.20');
      await _settle(tester);
      expect(find.byType(CommaRegisterPage), findsOneWidget);
      final address = tester.widget<TextField>(
        find.byKey(const ValueKey('register-address')),
      );
      expect(address.controller!.text, '192.168.43.20');
    });

    testWidgets('the registered comma at the typed IP is connected', (
      tester,
    ) async {
      await settings.update(
        (s) => s.copyWith(
          registeredComma: RegisteredComma(
            pin: fixturePin(pinDeviceA),
            host: '192.168.43.20',
          ),
        ),
      );
      probe.answers['192.168.43.31:8082'] = ProbeResult.kova(
        _comma('192.168.43.31'),
      );
      await pumpConnect(tester);
      await openIpSheet(tester);
      await submitIp(tester, '192.168.43.31');
      expect(find.byKey(const ValueKey('ip-connect-sheet')), findsNothing);
      expect(target.attached.single.host, '192.168.43.31');
    });

    testWidgets('another certificate than the registered comma is said first', (
      tester,
    ) async {
      await settings.update(
        (s) => s.copyWith(
          registeredComma: RegisteredComma(
            pin: fixturePin(pinDeviceA),
            host: '192.168.43.20',
          ),
        ),
      );
      probe.answers['192.168.43.20:8082'] = ProbeResult.kova(
        _comma('192.168.43.20', pinDeviceB),
      );
      await pumpConnect(tester);
      await openIpSheet(tester);
      await submitIp(tester, '192.168.43.20');
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.identityMismatch)),
        findsOneWidget,
      );
      expect(target.attached, isEmpty);
      expect(find.byKey(const ValueKey('ip-register-other')), findsOneWidget);
    });
  });

  group('콤마 등록', () {
    testWidgets('the token is hidden; empty fields say what is missing', (
      tester,
    ) async {
      await pumpRegister(tester, device: _comma('192.168.43.20'));
      await tester.enterText(
        find.byKey(const ValueKey('register-token')),
        testToken,
      );
      await tester.pump();
      final field = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('register-token')),
          matching: find.byType(EditableText),
        ),
      );
      expect(field.obscureText, isTrue);
      await tester.tap(find.byKey(const ValueKey('register-token-show')));
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('register-token')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isFalse,
      );
      await tester.enterText(
        find.byKey(const ValueKey('register-token')),
        'abc',
      );
      await tester.tap(find.byKey(const ValueKey('register-submit')));
      await tester.pump();
      expect(find.text('연결 토큰은 64자리 영문(a–f)·숫자예요.'), findsOneWidget);
      expect(find.text('인증서 지문을 넣거나 server.pem 파일을 골라 주세요.'), findsOneWidget);
      expect(tokens.tokens, isEmpty);
    });

    testWidgets('server.pem gives the pin; a private key is refused', (
      tester,
    ) async {
      await pumpRegister(tester, device: _comma('192.168.43.20'));
      picked = Uint8List.fromList(utf8.encode(fixtureText('device_a.key')));
      await tester.tap(find.byKey(const ValueKey('register-pick-pem')));
      await _settle(tester);
      expect(find.text(PemPinText.privateKey), findsOneWidget);
      expect(find.byKey(const ValueKey('register-pin-shown')), findsNothing);

      picked = Uint8List.fromList(utf8.encode(fixtureText('device_a.pem')));
      await tester.tap(find.byKey(const ValueKey('register-pick-pem')));
      await _settle(tester);
      expect(
        find.text('등록할 지문  ${fixturePin(pinDeviceA).grouped}'),
        findsOneWidget,
      );
      expect(find.text('찾은 콤마가 보여 준 지문과 같아요.'), findsOneWidget);
    });

    testWidgets('no trust on first sight: the seen fingerprint is only shown', (
      tester,
    ) async {
      await pumpRegister(tester, device: _comma('192.168.43.20'));
      // Nothing pasted or picked: the seen pin is not taken.
      await tester.enterText(
        find.byKey(const ValueKey('register-token')),
        testToken,
      );
      await tester.tap(find.byKey(const ValueKey('register-submit')));
      await _settle(tester);
      expect(find.text('인증서 지문을 넣거나 server.pem 파일을 골라 주세요.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('register-help-toggle')));
      await tester.pump();
      expect(find.byKey(const ValueKey('register-seen-pin')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('register-pin-command')),
        findsOneWidget,
      );
      expect(find.text(kovaPinCommand), findsOneWidget);
      expect(_CommaHealth.sent, isEmpty);
      expect(settings.value.registeredComma, isNull);
    });

    testWidgets('another pin: nothing sent, nothing saved, said plainly', (
      tester,
    ) async {
      await pumpRegister(tester, device: _comma('192.168.43.20'));
      await tester.enterText(
        find.byKey(const ValueKey('register-pin')),
        pinDeviceB,
      );
      await tester.enterText(
        find.byKey(const ValueKey('register-token')),
        testToken,
      );
      await tester.pump();
      expect(
        find.text('찾은 콤마가 보여 준 지문과 달라요. 관리자에게 받은 값을 다시 확인해 주세요.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('register-submit')));
      await _settle(tester);
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.identityMismatch)),
        findsOneWidget,
      );
      expect(_CommaHealth.sent, isEmpty);
      expect(tokens.tokens, isEmpty);
      expect(settings.value.registeredComma, isNull);
    });

    testWidgets('a wrong token: said plainly, nothing saved', (tester) async {
      await pumpRegister(tester, device: _comma('192.168.43.20'));
      await tester.enterText(
        find.byKey(const ValueKey('register-pin')),
        pinDeviceA,
      );
      await tester.enterText(
        find.byKey(const ValueKey('register-token')),
        'ab' * 32,
      );
      await tester.tap(find.byKey(const ValueKey('register-submit')));
      await _settle(tester);
      expect(
        find.text(KovaLinkText.message(KovaLinkProblem.tokenRejected)),
        findsOneWidget,
      );
      expect(tokens.tokens, isEmpty);
    });

    testWidgets(
      'right pin and token: saved, the token only in secure storage',
      (tester) async {
        KovaDevice? result;
        tester.view.physicalSize = const Size(420, 2200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async =>
                        result = await Navigator.of(context).push(
                          CommaRegisterPage.route(
                            link: link,
                            device: _comma('192.168.43.20'),
                          ),
                        ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        await tester.enterText(
          find.byKey(const ValueKey('register-pin')),
          'sha256/$pinDeviceAB64',
        );
        await tester.enterText(
          find.byKey(const ValueKey('register-token')),
          testToken.toUpperCase(),
        );
        await tester.tap(find.byKey(const ValueKey('register-submit')));
        await _settle(tester);
        expect(result?.pin?.hex, pinDeviceA);
        expect(result?.host, '192.168.43.20');
        expect(tokens.tokens, {pinDeviceA: testToken});
        expect(settings.value.registeredComma?.pin.hex, pinDeviceA);
        expect(jsonEncode(settings.value.toJson()), isNot(contains(testToken)));
        expect(find.byType(CommaRegisterPage), findsNothing);
      },
    );
  });

  group('connection screen', () {
    testWidgets('registered comma card: fingerprint, never the token; forget', (
      tester,
    ) async {
      await tokens.write(fixturePin(pinDeviceA), testToken);
      await settings.update(
        (s) => s.copyWith(
          registeredComma: RegisteredComma(
            pin: fixturePin(pinDeviceA),
            host: '192.168.43.20',
          ),
        ),
      );
      await pumpConnect(tester);
      expect(
        find.byKey(const ValueKey('registered-comma-card')),
        findsOneWidget,
      );
      expect(find.text('콤마 · 192.168.43.20'), findsOneWidget);
      expect(
        find.text('인증서 지문 ${fixturePin(pinDeviceA).short}'),
        findsOneWidget,
      );
      expect(find.textContaining(testToken), findsNothing);
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'no field on screen',
      );
      await tester.tap(find.byKey(const ValueKey('registered-comma-forget')));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('registered-comma-forget-ok')),
      );
      await _settle(tester);
      expect(settings.value.registeredComma, isNull);
      expect(tokens.tokens, isEmpty);
      expect(find.textContaining('아직 등록한 콤마가 없어요'), findsOneWidget);
    });

    testWidgets('camera waits for a comma; no comma.local anywhere', (
      tester,
    ) async {
      await pumpConnect(tester);
      expect(find.text('콤마를 연결하면 켤 수 있어요.'), findsOneWidget);
      final camera = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('카메라 켜기'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(camera.onPressed, isNull);
      expect(find.textContaining('comma.local'), findsNothing);
      expect(
        KovapilotEndpoints.fromOrigin(settings.value.lastDeviceEndpoint),
        isNull,
      );
    });
  });

  test('fixtures exist', () {
    expect(File('$tlsFixtures/device_a.pem').existsSync(), isTrue);
    expect(GatewayPin.fromHex(pinDeviceA), isNotNull);
  });
}
