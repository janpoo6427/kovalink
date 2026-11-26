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

class _TailscaleVpnCardState extends State<TailscaleVpnCard> {
  Timer? _poll;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _snapshot;

  TailscaleVpnClient get _client => TailscaleVpnClient(widget.link);

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
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
        }
      });
      if (action != null && result['state'] == 'authorizing') {
        _poll = Timer(
          const Duration(seconds: 2),
          () => _run(action: VpnAction.status),
        );
      }
    } on VpnException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Exception {
      if (mounted) {
        setState(
          () => _error = action == null
              ? 'VPN으로 콤마에 연결할 수 없어요. 휴대폰의 Tailscale 연결을 확인해 주세요.'
              : '콤마와의 Wi-Fi 연결을 확인해 주세요.',
        );
      }
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
              'connected' => '콤마의 VPN이 연결됐어요.',
              'authorizing' when login != null => '브라우저에서 콤마 등록을 승인해 주세요.',
              'authorizing' => 'Tailscale 로그인 주소를 받는 중이에요.',
              'notInstalled' => '콤마에 Tailscale 설치가 필요해요.',
              'approvalRequired' => 'Tailscale 관리자 콘솔에서 이 콤마를 승인해 주세요.',
              'needsLogin' => 'Tailscale 로그인이 필요해요.',
              'starting' => '콤마의 Tailscale이 시작 중이에요.',
              'gatewayUnavailable' => 'tailnet의 MagicDNS와 HTTPS 설정을 확인해 주세요.',
              'daemonUnavailable' => '콤마에서 Tailscale을 시작할 수 없어요.',
              _ when host != null => '휴대폰에서 Tailscale을 켜고 콤마 상태를 확인하세요.',
              _ => '같은 Wi-Fi에서 소유자 등록을 한 뒤 VPN을 연결하세요.',
            }),
            if (host != null) SelectableText(host),
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
                if (canManage && (status == null || status == 'needsLogin'))
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(action: VpnAction.connect),
                    child: const Text('Tailscale 연결'),
                  ),
                if (canManage && status == 'authorizing' && login != null)
                  FilledButton(
                    onPressed: () => _openLogin(login),
                    child: const Text('브라우저에서 로그인'),
                  ),
                if (host != null)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run(),
                    child: const Text('VPN으로 상태 보기'),
                  ),
                if (canManage &&
                    const {
                      'connected',
                      'authorizing',
                      'approvalRequired',
                      'gatewayUnavailable',
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
