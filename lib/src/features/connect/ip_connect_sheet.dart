import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';

/// What IP로 연결 ended with.
class IpConnectOutcome {
  const IpConnectOutcome.connected(KovaDevice this.connected) : register = null;
  const IpConnectOutcome.register(KovaDevice this.register) : connected = null;

  /// The registered comma answered there and is being connected.
  final KovaDevice? connected;

  /// A comma answered there that is not registered yet.
  final KovaDevice? register;
}

Future<IpConnectOutcome?> showIpConnectSheet(
  BuildContext context, {
  required AutoConnectController autoConnect,
  CommaLink? link,
}) => showModalBottomSheet<IpConnectOutcome>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => IpConnectSheet(autoConnect: autoConnect, link: link),
);

/// IP로 연결: the comma's current IP (or IP:port; 8082 when left out).
class IpConnectSheet extends StatefulWidget {
  const IpConnectSheet({required this.autoConnect, this.link, super.key});

  final AutoConnectController autoConnect;
  final CommaLink? link;

  @override
  State<IpConnectSheet> createState() => _IpConnectSheetState();
}

class _IpConnectSheetState extends State<IpConnectSheet> {
  final _address = TextEditingController();
  String? _error;
  KovaLinkProblem? _problem;
  KovaDevice? _other;
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    String? error;
    final target = parseCommaAddress(_address.text, onError: (e) => error = e);
    setState(() {
      _error = error;
      _problem = null;
      _other = null;
    });
    if (target == null) return;
    setState(() => _busy = true);
    final auto = widget.autoConnect;
    final result = await auto.check(target.host, target.port);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.outcome) {
      case ProbeOutcome.kova:
        final device = result.device!;
        if (auto.canAttach(device)) {
          Navigator.of(context).pop(IpConnectOutcome.connected(device));
          return;
        }
        final registered = widget.link?.registered;
        if (registered != null && device.secure) {
          // Another certificate than the registered comma's: say so first.
          setState(() {
            _problem = KovaLinkProblem.identityMismatch;
            _other = device;
          });
          return;
        }
        Navigator.of(context).pop(IpConnectOutcome.register(device));
      case ProbeOutcome.refused || ProbeOutcome.localOnly:
        setState(() => _problem = KovaLinkProblem.notAllowed);
      case ProbeOutcome.notKova when result.silent:
        setState(() => _problem = KovaLinkProblem.noAnswer);
      case ProbeOutcome.notKova || ProbeOutcome.noAnswer:
        setState(() => _problem = KovaLinkProblem.notKova);
    }
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF8E9DA9);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          key: const ValueKey('ip-connect-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'IP로 연결',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              CommaAddressText.whereToFind,
              key: ValueKey('ip-help'),
              style: TextStyle(color: muted, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('ip-input'),
              controller: _address,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _busy ? null : _submit(),
              decoration: InputDecoration(
                labelText: '콤마 IP',
                hintText: '예: 192.168.43.20',
                helperText: '포트가 다르면 192.168.43.20:8082처럼 적어 주세요.',
                errorText: _error,
              ),
            ),
            if (_problem case final problem?) ...[
              const SizedBox(height: 12),
              LinkProblemNote(problem: problem),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('ip-connect'),
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : const Text(
                            '연결',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            if (_other case final other?) ...[
              const SizedBox(height: 10),
              OutlinedButton(
                key: const ValueKey('ip-register-other'),
                onPressed: () =>
                    Navigator.of(context).pop(IpConnectOutcome.register(other)),
                child: const Text('이 콤마를 새로 등록'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
