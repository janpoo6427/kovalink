import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kovalink/src/network/tailscale_vpn.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:url_launcher/url_launcher.dart';

class TailscaleVpnCard extends StatefulWidget {
  const TailscaleVpnCard({required this.link, super.key});

  final CommaLink link;

  @override
  State<TailscaleVpnCard> createState() => _TailscaleVpnCardState();
}

class _TailscaleVpnCardState extends State<TailscaleVpnCard>
    with WidgetsBindingObserver {
  Timer? _poll;
  bool _busy = false;
  String? _error;
  // Status checks that could not reach the comma in a row (the app was in
  // the browser, the phone switched networks or VPN).
  int _missed = 0;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _snapshot;

  TailscaleVpnClient get _client => TailscaleVpnClient(widget.link);

  /// While the comma installs or starts Tailscale (or waits for the browser
  /// login) its state is asked again after this; null stops asking.
  static Duration? _pollDelay(Object? state) => switch (state) {
    'authorizing' => const Duration(seconds: 2),
    'installing' || 'starting' => const Duration(seconds: 3),
    'installFailed' => const Duration(seconds: 15),
    _ => null,
  };

  /// States the comma is still moving through; a check that does not reach
  /// it is tried again instead of stopping there.
  bool get _waiting {
    final state = _status?['state'];
    return state == null || _pollDelay(state) != null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The owner sees where the comma's Tailscale is without pressing
    // anything (the card is rebuilt when the phone becomes the owner).
    if (_client.canManage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(action: VpnAction.status);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  /// Back from the browser (Tailscale login): ask the comma at once.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _client.canManage &&
        (_waiting || _error != null)) {
      _run(action: VpnAction.status);
    }
  }

  Future<void> _run({VpnAction? action}) async {
    if (_busy) return;
    _poll?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      if (action == null || action == VpnAction.disconnect) _snapshot = null;
    });
    try {
      final result = action == null
          ? await _client.snapshot()
          : await _client.manage(action);
      if (!mounted) return;
      setState(() {
        if (action == null) {
          _snapshot = result;
        } else {
          _status = result;
          _missed = 0;
        }
      });
      final delay = action == null ? null : _pollDelay(result['state']);
      if (delay != null) {
        _poll = Timer(delay, () => _run(action: VpnAction.status));
      }
    } on VpnException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (!mounted) return;
      if (action == VpnAction.status && _waiting && _client.canManage) {
        // Keep asking: 3, 6, 12, then every 15 seconds.
        _missed++;
        final seconds = [3, 6, 12, 15][(_missed - 1).clamp(0, 3)];
        _poll = Timer(
          Duration(seconds: seconds),
          () => _run(action: VpnAction.status),
        );
        setState(
          () => _error = _missed < 3
              ? null
              : '콤마에 다시 닿으면 이어서 확인해요. 휴대폰이 콤마와 같은 Wi-Fi에 있는지 봐 주세요.',
        );
        return;
      }
      setState(
        () => _error = action == null
            ? 'VPN으로 콤마에 연결할 수 없어요. 휴대폰의 Tailscale 연결을 확인해 주세요.'
            : '콤마와의 Wi-Fi 연결을 확인해 주세요.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLogin(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on Exception {
      // The system browser may be unavailable on this platform.
    }
    if (mounted) setState(() => _error = '시스템 브라우저를 열 수 없어요.');
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('VPN 연결 해제'),
        content: const Text('콤마의 Tailscale 등록을 해제해요. 다시 연결하려면 로그인해야 해요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(action: VpnAction.disconnect);
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _client.canManage;
    final host = widget.link.registered?.vpnHost;
    final status = _status?['state'];
    final login = TailscaleVpnClient.loginUri(_status?['loginUrl']);
    final scene = _snapshot?['telemetry'];
    final speed = scene is Map ? scene['speedMps'] : null;
    final branch = _snapshot?['branch'];
    final version = _snapshot?['version'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tailscale VPN',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(switch (status) {
              'connected' =>
                '콤마의 VPN이 켜져 있어요. 다른 곳에서도 휴대폰 Tailscale을 켜면 VPN IP로 연결돼요.',
              'stopped' => '콤마의 VPN이 꺼져 있어요.',
              'authorizing' when login != null => '브라우저에서 콤마 등록을 승인해 주세요.',
              'authorizing' => 'Tailscale 로그인 주소를 받는 중이에요.',
              'installing' =>
                '콤마가 Tailscale을 받아 설치하고 있어요. 콤마가 인터넷에 연결돼 있어야 해요.',
              'installFailed' =>
                '콤마가 Tailscale을 받지 못했어요. 콤마의 인터넷 연결을 확인해 주세요. 콤마가 알아서 다시 받아요.',
              'notInstalled' =>
                '콤마에 Tailscale이 없어요. kovapilot을 업데이트하면 콤마가 알아서 설치해요.',
              'approvalRequired' => 'Tailscale 관리자 콘솔에서 이 콤마를 승인해 주세요.',
              'needsLogin' => 'Tailscale 로그인이 필요해요.',
              'starting' => '콤마의 VPN이 켜지는 중이에요.',
              'gatewayUnavailable' => 'tailnet의 MagicDNS와 HTTPS 설정을 확인해 주세요.',
              'daemonUnavailable' => '콤마에서 Tailscale을 시작할 수 없어요.',
              null when canManage && _error == null => '콤마의 VPN 상태를 확인하고 있어요.',
              _ when host != null => '휴대폰에서 Tailscale을 켜면 VPN IP로 콤마에 연결해요.',
              _ => '같은 Wi-Fi에서 소유자 등록을 한 뒤 VPN을 연결하세요.',
            }),
            if (host != null) SelectableText('VPN IP $host'),
            if (canManage || host != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '콤마를 켜면 VPN도 알아서 켜져요. 콤마 화면에서 지금 쓰는 Wi-Fi를 잊거나 다른 Wi-Fi로 바꾸거나 테더링을 켜면, 또는 여기서 끄면, 다시 켤 때까지 꺼져 있어요. 다시 켜려면 같은 Wi-Fi에서 \'VPN 켜기\'를 눌러 주세요.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (version is String && branch is String)
              Text('$branch · $version'),
            if (_snapshot != null)
              Text(
                speed is num && speed.isFinite
                    ? '조회 시 속도 ${(speed * 3.6).toStringAsFixed(0)} km/h'
                    : '현재 주행 정보를 받을 수 없어요.',
              ),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (canManage)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(action: VpnAction.status),
                    child: const Text('VPN 상태 확인'),
                  ),
                if (canManage && status == 'needsLogin')
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(action: VpnAction.connect),
                    child: const Text('Tailscale 연결'),
                  ),
                if (canManage && status == 'stopped')
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(action: VpnAction.connect),
                    child: const Text('VPN 켜기'),
                  ),
                if (canManage && status == 'connected')
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _run(action: VpnAction.stop),
                    child: const Text('VPN 끄기'),
                  ),
                if (canManage && status == 'authorizing' && login != null)
                  FilledButton(
                    onPressed: () => _openLogin(login),
                    child: const Text('브라우저에서 로그인'),
                  ),
                if (canManage &&
                    const {
                      'connected',
                      'authorizing',
                      'approvalRequired',
                      'gatewayUnavailable',
                      'stopped',
                      'starting',
                    }.contains(status))
                  TextButton(
                    onPressed: _busy ? null : _disconnect,
                    child: const Text('연결 해제'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
