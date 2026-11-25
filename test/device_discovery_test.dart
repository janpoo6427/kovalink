import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';

const _health =
    '{"status":"ok","schemaVersion":1,"bindScope":"loopback","authentication":"localProcessOnly"}';

void main() {
  group('interface classification', () {
    test('Wi-Fi, hotspot, USB and wired interfaces are scanned', () {
      for (final (name, kind) in [
        ('wlan0', NetworkKind.wifi),
        ('en0', NetworkKind.wifi),
        ('wlp2s0', NetworkKind.wifi),
        ('ap0', NetworkKind.hotspot),
        ('swlan0', NetworkKind.hotspot),
        ('softap0', NetworkKind.hotspot),
        ('bridge100', NetworkKind.hotspot),
        ('rndis0', NetworkKind.usb),
        ('usb0', NetworkKind.usb),
        ('eth0', NetworkKind.ethernet),
      ]) {
        expect(classifyInterface(name), kind, reason: name);
        expect(kind.scannable, isTrue, reason: name);
      }
    });

    test('mobile data, VPN, loopback and unknown interfaces are not', () {
      for (final (name, kind) in [
        ('rmnet_data0', NetworkKind.cellular),
        ('rmnet0', NetworkKind.cellular),
        ('ccmni1', NetworkKind.cellular),
        ('pdp_ip0', NetworkKind.cellular),
        ('v4-rmnet_data0', NetworkKind.cellular),
        ('clat4', NetworkKind.cellular),
        ('tun0', NetworkKind.vpn),
        ('utun3', NetworkKind.vpn),
        ('ipsec0', NetworkKind.vpn),
        ('lo', NetworkKind.loopback),
        ('docker0', NetworkKind.other),
        ('awdl0', NetworkKind.other),
        ('p2p0', NetworkKind.other),
        ('weird7', NetworkKind.other),
      ]) {
        expect(classifyInterface(name), kind, reason: name);
        expect(kind.scannable, isFalse, reason: name);
      }
    });

    test('only policy-approved addresses are scannable', () {
      expect(LocalNetwork.named('wlan0', '192.168.0.23').scannable, isTrue);
      expect(LocalNetwork.named('ap0', '10.42.0.1').scannable, isTrue);
      expect(LocalNetwork.named('wlan0', '172.20.10.2').scannable, isTrue);
      // Private, but on mobile data: never scanned.
      expect(LocalNetwork.named('rmnet_data0', '10.12.3.4').scannable, isFalse);
      // Public, carrier-grade NAT and IPv4 link-local are outside the policy.
      expect(LocalNetwork.named('wlan0', '8.8.4.4').scannable, isFalse);
      expect(LocalNetwork.named('wlan0', '100.64.1.2').scannable, isFalse);
      expect(LocalNetwork.named('wlan0', '169.254.3.3').scannable, isFalse);
      expect(LocalNetwork.named('wlan0', '172.32.0.5').scannable, isFalse);
    });
  });

  group('subnet hosts', () {
    test('a /24 without network, broadcast and own address', () {
      final hosts = subnetHosts(LocalNetwork.named('wlan0', '192.168.0.23'));
      expect(hosts, hasLength(253));
      expect(hosts.first, '192.168.0.1');
      expect(hosts.last, '192.168.0.254');
      expect(hosts, isNot(contains('192.168.0.23')));
      expect(hosts, isNot(contains('192.168.0.0')));
      expect(hosts, isNot(contains('192.168.0.255')));
      for (final host in hosts) {
        expect(
          LocalEndpointPolicy.validateSettings('http://$host:8082'),
          isNull,
        );
      }
    });

    test('nothing for cellular or public networks', () {
      expect(subnetHosts(LocalNetwork.named('rmnet0', '10.1.2.3')), isEmpty);
      expect(subnetHosts(LocalNetwork.named('wlan0', '1.1.1.9')), isEmpty);
    });
  });

  group('discovery plan', () {
    final wifi = LocalNetwork.named('wlan0', '192.168.0.23');
    final hotspot = LocalNetwork.named('swlan0', '10.155.70.1');
    final cellular = LocalNetwork.named('rmnet_data0', '10.20.30.40');

    test('last address, then saved, then router, then the subnet', () {
      final plan = DiscoveryPlan.build(
        networks: [wifi, cellular],
        lastEndpoint: 'http://192.168.0.40:8082',
        knownEndpoints: ['http://comma.local:8082'],
      );
      expect(plan.priority.map((t) => '${t.label} ${t.source.name}'), [
        '192.168.0.40:8082 last',
        'comma.local:8082 known',
        '192.168.0.1:8082 router',
      ]);
      expect(plan.scan, hasLength(251));
      expect(plan.scan.first.label, '192.168.0.2:8082');
      expect(plan.all.map((t) => t.key).toSet(), hasLength(plan.length));
      // Mobile data subnet is never in the plan.
      expect(plan.all.where((t) => t.host.startsWith('10.20.30.')), isEmpty);
    });

    test('hotspot AP: own .1 is skipped, clients are scanned', () {
      final plan = DiscoveryPlan.build(networks: [hotspot]);
      expect(plan.priority, isEmpty);
      expect(plan.scan, hasLength(253));
      expect(plan.scan.any((t) => t.host == '10.155.70.1'), isFalse);
    });

    test('no Wi-Fi/hotspot: nothing at all, not even saved addresses', () {
      final plan = DiscoveryPlan.build(
        networks: [cellular],
        lastEndpoint: 'http://192.168.0.40:8082',
        knownEndpoints: ['http://comma.local:8082'],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('a last IP outside every scanned subnet is not tried', () {
      // It would be routed over mobile data.
      final plan = DiscoveryPlan.build(
        networks: [wifi],
        lastEndpoint: 'http://10.0.7.9:8082',
      );
      expect(plan.priority.map((t) => t.host), ['192.168.0.1']);
    });

    test('public addresses never enter the plan', () {
      final plan = DiscoveryPlan.build(
        networks: [wifi, LocalNetwork.named('wlan1', '203.0.113.7')],
        lastEndpoint: 'http://203.0.113.9:8082',
        knownEndpoints: ['http://example.com:8082', 'http://8.8.8.8:8082'],
      );
      for (final t in plan.all) {
        expect(t.host, startsWith('192.168.0.'));
      }
    });

    test('random interfaces: every target passes the endpoint policy', () {
      final random = Random(7);
      const names = ['wlan0', 'ap0', 'rmnet0', 'en0', 'tun0', 'eth0', 'usb0'];
      for (var round = 0; round < 60; round++) {
        final networks = [
          for (var i = 0; i < 3; i++)
            LocalNetwork.named(
              names[random.nextInt(names.length)],
              List.generate(4, (_) => random.nextInt(256)).join('.'),
            ),
          if (round.isEven) LocalNetwork.named('wlan0', '192.168.1.50'),
        ];
        final plan = DiscoveryPlan.build(
          networks: networks,
          ports: const [8082, 18082],
        );
        for (final t in plan.all) {
          expect(
            LocalEndpointPolicy.validateSettings('http://${t.host}:${t.port}'),
            isNull,
            reason: '$t from $networks',
          );
          expect(
            networks.any(
              (n) =>
                  n.scannable &&
                  n.subnetLabel ==
                      '${t.host.split('.').take(3).join('.')}.0/24',
            ),
            isTrue,
            reason: '$t is outside every scannable network',
          );
        }
      }
    });

    test('several ports are probed on every host', () {
      final plan = DiscoveryPlan.build(
        networks: [wifi],
        ports: const [8082, 18082],
      );
      expect(plan.priority.map((t) => t.label), [
        '192.168.0.1:8082',
        '192.168.0.1:18082',
      ]);
      expect(plan.scan, hasLength(252 * 2));
    });
  });

  group('protocol check', () {
    test('kovapilot health is a device', () {
      final r = judgeHealthResponse('192.168.0.40', 8082, 200, _health);
      expect(r.outcome, ProbeOutcome.kova);
      expect(r.device!.settingsEndpoint, 'http://192.168.0.40:8082');
      expect(r.device!.bindScope, 'loopback');
    });

    test('other answers are not', () {
      for (final (code, body) in [
        (404, _health),
        (200, '<html>router login</html>'),
        (200, '{"status":"fine","schemaVersion":1}'),
        (200, '{"status":"ok"}'),
        (200, '{"status":"ok","schemaVersion":2}'),
        (200, '[1,2]'),
      ]) {
        expect(
          judgeHealthResponse('192.168.0.40', 8082, code, body).outcome,
          ProbeOutcome.notKova,
          reason: '$code $body',
        );
      }
    });
  });

  group('HttpDeviceProbe (loopback sockets)', () {
    late HttpDeviceProbe probe;
    setUp(() => probe = HttpDeviceProbe());
    tearDown(() => probe.close());

    Future<HttpServer> serve(String body, {int status = 200}) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType.json
          ..write(body);
        request.response.close();
      });
      return server;
    }

    test('finds a kovapilot gateway', () async {
      final server = await serve(_health);
      final r = await probe.probe('127.0.0.1', server.port);
      expect(r.outcome, ProbeOutcome.kova);
      await server.close(force: true);
    });

    test('an open port with another web server is not a device', () async {
      final server = await serve(jsonEncode({'hello': 'world'}));
      final r = await probe.probe('127.0.0.1', server.port);
      expect(r.outcome, ProbeOutcome.notKova);
      await server.close(force: true);
    });

    test('a port that accepts but never answers times out', () async {
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      silent.listen(held.add);
      final watch = Stopwatch()..start();
      final r = await probe.probe('127.0.0.1', silent.port);
      expect(r.outcome, isNot(ProbeOutcome.kova));
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });

    test('a closed port is no answer', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final r = await probe.probe('127.0.0.1', port);
      expect(r.outcome, ProbeOutcome.noAnswer);
    });

    test('public hosts are refused before any connection', () async {
      final watch = Stopwatch()..start();
      final r = await probe.probe('8.8.8.8', 8082);
      expect(r.outcome, ProbeOutcome.noAnswer);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)));
    });
  });
}
