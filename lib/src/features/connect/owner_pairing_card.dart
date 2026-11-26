import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/network/owner_pairing.dart';
import 'package:kovalink/src/services/comma_link.dart';

/// 소유자 등록 on automatic Wi-Fi: the comma shows a code, this phone types
/// it and becomes the owner (버전 바꾸기, 콤마 다시 켜기, Tailscale).
class OwnerPairingCard extends StatefulWidget {
  const OwnerPairingCard({required this.link, super.key});

  final CommaLink link;

  @override
  State<OwnerPairingCard> createState() => _OwnerPairingCardState();
}

class _OwnerPairingCardState extends State<OwnerPairingCard> {
  bool _busy = false;
  String? _message;

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final request = await widget.link.requestOwnerCode();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (request) {
      case OwnerCodeRefused(:final message):
        setState(() => _message = message);
      case OwnerCodeShown(:final seconds):
        final paired = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) =>
              OwnerCodeDialog(link: widget.link, seconds: seconds),
        );
        if (paired == true && mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('이 휴대폰을 소유자로 등록했어요.')));
        }
    }
  }

  Future<void> _forget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('소유자 등록을 지울까요?'),
        content: const Text(
          '이 휴대폰에 저장한 소유자 토큰을 지워요. 다시 쓰려면 콤마 화면의 코드로 다시 등록해야 해요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('owner-forget-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.link.forget();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final owner = link.isOwner;
    final available = link.health?.ownerPairing == true;
    const muted = Color(0xFF8E9DA9);
    final text = owner
        ? '이 휴대폰이 콤마의 소유자로 등록돼 있어요. 버전 바꾸기, 콤마 다시 켜기, Tailscale을 쓸 수 있어요.'
        : link.ownerRejected
        ? '소유자 등록이 바뀌었어요. 다른 휴대폰이 새로 등록했을 수 있어요. 이 휴대폰을 쓰려면 다시 등록해 주세요.'
        : available
        ? '소유자로 등록하면 이 휴대폰에서 버전 바꾸기, 콤마 다시 켜기, Tailscale을 쓸 수 있어요. 시동을 끄고 눌러 주세요.'
        : '콤마의 kovapilot을 업데이트하면 앱에서 소유자로 등록할 수 있어요.';
    return Card(
      key: const ValueKey('owner-pairing-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  owner ? Icons.verified_user_outlined : Icons.key_outlined,
                  color: const Color(0xFF58F2C2),
                ),
                const SizedBox(width: 10),
                const Text(
                  '소유자 등록',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  owner ? '등록됨' : '안 됨',
                  key: const ValueKey('owner-pairing-state'),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              text,
              style: const TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            if (_message case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                key: const ValueKey('owner-pairing-message'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            if (available || owner) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (available && owner)
                    OutlinedButton(
                      key: const ValueKey('owner-pairing-start'),
                      onPressed: _busy ? null : _pair,
                      child: Text(_busy ? '코드를 요청하는 중' : '다시 등록'),
                    )
                  else if (available)
                    FilledButton(
                      key: const ValueKey('owner-pairing-start'),
                      onPressed: _busy ? null : _pair,
                      child: Text(_busy ? '코드를 요청하는 중' : '소유자로 등록'),
                    ),
                  if (owner)
                    TextButton(
                      key: const ValueKey('owner-forget'),
                      onPressed: _busy ? null : _forget,
                      child: const Text('등록 지우기'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Types the six digits shown on the comma screen.
class OwnerCodeDialog extends StatefulWidget {
  const OwnerCodeDialog({required this.link, required this.seconds, super.key});

  final CommaLink link;
  final int seconds;

  @override
  State<OwnerCodeDialog> createState() => _OwnerCodeDialogState();
}

class _OwnerCodeDialogState extends State<OwnerCodeDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (!OwnerPairingClient.codePattern.hasMatch(code)) {
      setState(() => _error = '숫자 6자리를 넣어 주세요.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.link.confirmOwnerCode(code);
    if (!mounted) return;
    switch (result) {
      case OwnerCodeAccepted():
        Navigator.of(context).pop(true);
      case OwnerCodeWrong(:final remaining):
        setState(() {
          _busy = false;
          _error = remaining == null
              ? '코드가 맞지 않아요.'
              : '코드가 맞지 않아요. $remaining번 더 넣을 수 있어요.';
        });
      case OwnerCodeFailed(:final message):
        setState(() {
          _busy = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final minutes = (widget.seconds / 60).ceil();
    return AlertDialog(
      key: const ValueKey('owner-code-dialog'),
      title: const Text('콤마 화면의 코드 넣기'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '콤마 화면 알림에 나온 6자리 숫자를 넣어 주세요. $minutes분 안에 넣어야 해요.',
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('owner-code-field'),
            controller: _code,
            autofocus: true,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 6,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            decoration: InputDecoration(
              hintText: '000000',
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('owner-code-cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('닫기'),
        ),
        FilledButton(
          key: const ValueKey('owner-code-submit'),
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '확인하는 중' : '등록'),
        ),
      ],
    );
  }
}
