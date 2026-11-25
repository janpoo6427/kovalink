import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/network/comma_link_text.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/network/gateway_pin.dart';
import 'package:kovalink/src/network/gateway_session.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/widgets/page_header.dart';
import 'package:kovalink/src/widgets/readable_width.dart';

/// Reads a picked server.pem (tests pass a fake).
typedef PemFilePicker = Future<Uint8List?> Function();

/// The platform document picker; PEM files are small, bigger ones are
/// refused before they are read.
Future<Uint8List?> pickPemFileWithSystemPicker() async {
  final file = await FilePicker.pickFile(dialogTitle: '콤마 인증서(server.pem) 선택');
  if (file == null) return null;
  final length = await file.length();
  if (length != null && length > maxPemBytes) {
    throw const FormatException(PemPinText.unreadable);
  }
  return file.readAsBytes();
}

const maxPemBytes = 64 * 1024;

/// 콤마 등록: the comma's IP, the token the administrator gave, and its
/// certificate (pin pasted, or server.pem picked and the pin computed here).
/// Nothing is saved until the comma answered with that certificate and
/// accepted that token. A certificate seen on the network is shown for
/// comparison only; it is never taken as the pin.
class CommaRegisterPage extends StatefulWidget {
  const CommaRegisterPage({
    required this.link,
    this.device,
    this.pemPicker = pickPemFileWithSystemPicker,
    super.key,
  });

  static const routeName = '${KovaRoutes.connect}/register';

  /// Pops with the registered comma as a [KovaDevice] (to connect), or null.
  static Route<KovaDevice> route({
    required CommaLink link,
    KovaDevice? device,
    PemFilePicker pemPicker = pickPemFileWithSystemPicker,
  }) => KovaPageRoute<KovaDevice>(
    name: routeName,
    builder: (context) => KovaPage(
      backTooltip: '장치 연결로 돌아가기',
      child: CommaRegisterPage(
        link: link,
        device: device,
        pemPicker: pemPicker,
      ),
    ),
  );

  final CommaLink link;

  /// The comma picked in the Finder or found by IP (address and the
  /// fingerprint it showed); null to type the IP.
  final KovaDevice? device;
  final PemFilePicker pemPicker;

  @override
  State<CommaRegisterPage> createState() => _CommaRegisterPageState();
}

class _CommaRegisterPageState extends State<CommaRegisterPage> {
  late final _address = TextEditingController(
    text:
        widget.device?.displayName ??
        widget.link.registered?.endpoints.displayName ??
        '',
  );
  final _token = TextEditingController();
  final _pinText = TextEditingController();
  bool _showToken = false;
  bool _busy = false;
  bool _help = false;
  String? _addressError;
  String? _tokenError;
  String? _pinError;
  String? _fileNote;
  GatewayPin? _filePin;
  KovaLinkProblem? _problem;

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    _pinText.dispose();
    super.dispose();
  }

  GatewayPin? get _pin => _pinText.text.trim().isEmpty
      ? _filePin
      : GatewayPin.tryParse(_pinText.text);

  Future<void> _pickPem() async {
    Uint8List? bytes;
    try {
      bytes = await widget.pemPicker();
    } on Object {
      if (mounted) _setFile(null, PemPinText.unreadable);
      return;
    }
    if (!mounted || bytes == null) return;
    if (bytes.length > maxPemBytes) {
      _setFile(null, PemPinText.unreadable);
      return;
    }
    switch (pinFromPem(utf8.decode(bytes, allowMalformed: true))) {
      case PemPinFound(:final pin):
        _pinText.clear();
        _setFile(pin, '파일에서 지문을 읽었어요.');
      case PemPinRefused(:final reason):
        _setFile(null, reason);
    }
  }

  void _setFile(GatewayPin? pin, String note) => setState(() {
    _filePin = pin;
    _fileNote = note;
    _pinError = null;
  });

  Future<void> _submit() async {
    String? addressError;
    final target = parseCommaAddress(
      _address.text,
      onError: (e) => addressError = e,
    );
    final token = GatewayCredentials.normalizeToken(_token.text);
    final pin = _pin;
    setState(() {
      _addressError = addressError;
      _tokenError = token == null ? '연결 토큰은 64자리 영문(a–f)·숫자예요.' : null;
      _pinError = pin == null
          ? (_pinText.text.trim().isEmpty
                ? '인증서 지문을 넣거나 server.pem 파일을 골라 주세요.'
                : '지문을 읽지 못했어요. 관리자에게 받은 64자리 지문을 그대로 넣어 주세요.')
          : null;
      _problem = null;
    });
    if (target == null || token == null || pin == null) return;
    if (LocalEndpointPolicy.isLoopbackHost(target.host)) {
      setState(() => _addressError = '휴대폰이 아니라 콤마의 IP를 넣어 주세요.');
      return;
    }
    setState(() => _busy = true);
    final problem = await widget.link.register(
      host: target.host,
      port: target.port,
      pin: pin,
      token: token,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
    });
    if (problem == null) {
      Navigator.of(context).pop(
        KovaDevice(
          host: target.host,
          port: target.port,
          secure: true,
          pin: pin,
          bindScope: 'wifi',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const muted = Color(0xFF8E9DA9);
    final pin = _pin;
    final seen = widget.device?.pin;
    return ReadableListView(
      children: [
        const PageHeader(
          title: '콤마 등록',
          subtitle:
              '관리자에게 받은 연결 토큰과 콤마의 인증서 정보를 넣어 주세요. '
              '처음 보는 콤마를 그냥 믿지 않아요.',
        ),
        const SizedBox(height: 20),
        Card(
          key: const ValueKey('register-card'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('register-address'),
                  controller: _address,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '콤마 IP',
                    hintText: '예: 192.168.43.20',
                    errorText: _addressError,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  CommaAddressText.whereToFind,
                  style: TextStyle(color: muted, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('register-token'),
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: '연결 토큰',
                    helperText: '64자리예요. 휴대폰의 보안 저장소에만 보관해요.',
                    errorText: _tokenError,
                    suffixIcon: IconButton(
                      key: const ValueKey('register-token-show'),
                      tooltip: _showToken ? '토큰 가리기' : '토큰 보기',
                      icon: Icon(
                        _showToken ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  '인증서 정보',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('register-pin'),
                  controller: _pinText,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 2,
                  minLines: 1,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: '인증서 지문 붙여넣기',
                    hintText: '64자리 지문',
                    errorText: _pinError,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('또는', style: TextStyle(color: muted)),
                    OutlinedButton.icon(
                      key: const ValueKey('register-pick-pem'),
                      onPressed: _busy ? null : _pickPem,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: const Text('server.pem 파일 고르기'),
                    ),
                  ],
                ),
                if (_fileNote case final note?) ...[
                  const SizedBox(height: 6),
                  Text(
                    note,
                    key: const ValueKey('register-file-note'),
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
                if (pin != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '등록할 지문  ${pin.grouped}',
                    key: const ValueKey('register-pin-shown'),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (seen != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      pin.matches(seen)
                          ? '찾은 콤마가 보여 준 지문과 같아요.'
                          : '찾은 콤마가 보여 준 지문과 달라요. 관리자에게 받은 값을 다시 확인해 주세요.',
                      key: const ValueKey('register-pin-compare'),
                      style: TextStyle(
                        fontSize: 12,
                        color: pin.matches(seen)
                            ? const Color(0xFF58F2C2)
                            : const Color(0xFFFF9F5A),
                      ),
                    ),
                  ],
                ],
                if (_problem case final problem?) ...[
                  const SizedBox(height: 14),
                  LinkProblemNote(problem: problem),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('register-submit'),
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
                            '확인하고 등록',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          key: const ValueKey('register-help-toggle'),
          onPressed: () => setState(() => _help = !_help),
          icon: Icon(_help ? Icons.expand_less : Icons.expand_more, size: 18),
          label: Text(_help ? '접기' : '자세히 보기'),
        ),
        if (_help)
          Card(
            key: const ValueKey('register-help'),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '인증서 지문은 콤마 인증서에 든 공개 키의 SHA-256 값이에요. '
                    'IP가 바뀌어도 지문이 같으면 같은 콤마로 알아보고, 지문이 맞을 때만 연결 토큰을 보내요.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '관리자는 콤마에서 이 명령으로 지문을 볼 수 있어요.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                  const SizedBox(height: 6),
                  _CommandBox(command: kovaPinCommand),
                  const SizedBox(height: 10),
                  const Text(
                    'server.pem 파일을 고르면 앱이 같은 지문을 계산해요. 개인 키 파일(server.key)은 고르지 마세요.',
                    style: TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                  if (seen != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      '찾은 콤마가 보여 준 지문\n${seen.grouped}',
                      key: const ValueKey('register-seen-pin'),
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: muted,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '비교용으로만 보여 줘요. 관리자에게 받은 값과 같을 때만 등록돼요.',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _CommandBox extends StatelessWidget {
  const _CommandBox({required this.command});
  final String command;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const ValueKey('register-pin-command'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0A1016) : const Color(0xFFF0F3F6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
          ),
          IconButton(
            tooltip: '명령 복사',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}
