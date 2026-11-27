// "kovapilot 설정" tab: connection card + settings drawn from the gateway's
// kova_params document. Nothing here lists settings by name; titles,
// descriptions, groups and options all come from the document.
import 'package:flutter/material.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';

const _muted = Color(0xFF8E9DA9);
const _accent = Color(0xFF58F2C2);
const _warn = Color(0xFFFFC857);
const _danger = Color(0xFFFF6B72);

class KovaParamsPanel extends StatelessWidget {
  const KovaParamsPanel({
    required this.controller,
    required this.address,
    this.now,
    super.key,
  });

  final KovaParamsController controller;

  /// kovapilot settings address of the comma found or entered (not
  /// editable); null before there is one.
  final String? address;

  /// Clock for "n초 전" (tests/captures).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final document = controller.document;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KovaConnectionCard(
              controller: controller,
              address: address,
              now: now,
            ),
            if (document == null)
              const Card(
                key: ValueKey('kova-empty'),
                child: ListTile(
                  leading: Icon(Icons.tune_outlined),
                  title: Text('연결하면 설정이 여기에 나와요.'),
                ),
              )
            else ...[
              for (final group in document.groups)
                _GroupCard(
                  group: group,
                  document: document,
                  controller: controller,
                ),
              if (document.groups.isEmpty)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.inbox_outlined),
                    title: Text('바꿀 수 있는 설정이 없어요.'),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

String _ago(DateTime? at, DateTime now) {
  if (at == null) return '아직 못 불러옴';
  final seconds = now.difference(at).inSeconds;
  if (seconds < 5) return '방금 불러옴';
  if (seconds < 60) return '$seconds초 전에 불러옴';
  return '${seconds ~/ 60}분 전에 불러옴';
}

class KovaConnectionCard extends StatelessWidget {
  const KovaConnectionCard({
    required this.controller,
    required this.address,
    this.now,
    super.key,
  });

  final KovaParamsController controller;

  /// The found comma's settings address; null before one is found.
  final String? address;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final status = controller.status;
    final (label, color, icon) = switch (status) {
      KovaLinkStatus.disconnected => ('연결 안 됨', _muted, Icons.link_off),
      KovaLinkStatus.connecting => ('연결 중', _warn, Icons.sync),
      KovaLinkStatus.connected => ('연결됨', _accent, Icons.link),
      KovaLinkStatus.stale => ('다시 연결하는 중', _warn, Icons.sync_problem),
    };
    final document = controller.document;
    final lock = controller.writeLock;
    final health = controller.health;
    final clock = now ?? DateTime.now;
    final shownAddress = controller.endpoint ?? address ?? '아직 찾은 콤마가 없어요';
    return Card(
      key: const ValueKey('kova-connection-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'kovapilot',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
                Container(
                  key: const ValueKey('kova-status'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              shownAddress,
              style: const TextStyle(color: _muted, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
            if (document != null || health != null)
              Text(
                _ago(controller.lastReadAt, clock()),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            if (document != null) ...[
              const SizedBox(height: 10),
              _Banner(
                key: const ValueKey('kova-write-banner'),
                color: lock == KovaWriteLock.none ? _accent : _warn,
                icon: lock == KovaWriteLock.none
                    ? Icons.lock_open
                    : Icons.lock_outline,
                text: lock == KovaWriteLock.none
                    ? (controller.isLoopback
                          ? '개발용 연결이에요. 설정을 바꿀 수 있어요.'
                          : '설정을 바꿀 수 있어요.')
                    : KovaParamsController.writeLockReason(lock),
              ),
              if (document.deviceOffroad == false &&
                  document.deviceParked != true &&
                  document.settings.values.any(
                    (s) =>
                        s.longitudinalBlock == null &&
                        !s.saveAnytime &&
                        s.access == KovaParamAccess.readWrite &&
                        (s.applyPolicy == KovaApplyPolicy.offroad ||
                            s.applyPolicy == KovaApplyPolicy.parked ||
                            s.applyPolicy == KovaApplyPolicy.restart),
                  )) ...[
                const SizedBox(height: 6),
                const _Banner(
                  key: ValueKey('kova-onroad-banner'),
                  color: _warn,
                  icon: Icons.directions_car_filled_outlined,
                  text: '일부 설정은 P에 두고 완전히 정차해야 바꿀 수 있어요.',
                ),
              ],
            ],
            if (controller.error case final error?) ...[
              const SizedBox(height: 8),
              Text(
                error,
                key: const ValueKey('kova-error'),
                style: const TextStyle(color: _danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (status == KovaLinkStatus.disconnected)
                  FilledButton.icon(
                    key: const ValueKey('kova-connect'),
                    onPressed: address == null
                        ? null
                        : () => controller.connect(address!),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('연결'),
                  )
                else if (status == KovaLinkStatus.connecting)
                  const FilledButton(onPressed: null, child: Text('연결 중…'))
                else ...[
                  OutlinedButton.icon(
                    key: const ValueKey('kova-refresh'),
                    onPressed: controller.refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('새로고침'),
                  ),
                  TextButton(
                    key: const ValueKey('kova-disconnect'),
                    onPressed: controller.disconnect,
                    child: const Text('연결 끊기'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    super.key,
  });

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12.5, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.document,
    required this.controller,
  });

  final KovaParamGroup group;
  final KovaParamsDocument document;
  final KovaParamsController controller;

  @override
  Widget build(BuildContext context) {
    final locale = document.defaultLocale;
    final title = group.title?.resolve(defaultLocale: locale) ?? '기타';
    final description = group.description?.resolve(defaultLocale: locale);
    // Settings that need openpilot longitudinal control are replaced, at the
    // first one's place, by a note naming them while it does not run.
    final blocked = [
      for (final setting in group.settings)
        if (setting.longitudinalBlock != null) setting,
    ];
    final shown = group.settings.length - blocked.length;
    return Card(
      key: ValueKey('kova-group-${group.id}'),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('kova-group-panel-${group.id}'),
        maintainState: true,
        title: Text(title),
        subtitle: Text(
          blocked.isEmpty
              ? '$shown개 항목'
              : '$shown개 항목 · 종방향 제어 필요 ${blocked.length}개',
        ),
        children: [
          if (description != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(description),
            ),
          for (final setting in group.settings)
            if (setting.longitudinalBlock == null) ...[
              const Divider(height: 1),
              KovaSettingTile(
                setting: setting,
                document: document,
                controller: controller,
              ),
            ] else if (identical(setting, blocked.first)) ...[
              const Divider(height: 1),
              KovaLongitudinalOnlyNote(
                groupId: group.id,
                reason: setting.longitudinalBlock!,
                features: [
                  for (final s in blocked)
                    s.title.resolve(defaultLocale: locale),
                ],
              ),
            ],
        ],
      ),
    );
  }
}

/// Stands in for settings that need openpilot longitudinal control while it
/// is off, saved for the next start, or unsupported on this vehicle.
class KovaLongitudinalOnlyNote extends StatelessWidget {
  KovaLongitudinalOnlyNote({
    required this.groupId,
    required this.reason,
    required this.features,
  }) : super(key: ValueKey('kova-long-only-$groupId'));

  final String groupId;

  /// [KovaParamSetting.longitudinalBlock] of the hidden settings.
  final String reason;
  final List<String> features;

  static String message(String reason, List<String> features) {
    final names = features.join(', ');
    return switch (reason) {
      'pendingRestart' => '종방향 제어가 저장됐어요 · 다음 시동부터 사용할 수 있는 기능: $names',
      'unsupported' => '이 차량은 종방향 제어를 지원하지 않아요 · 사용할 수 없는 기능: $names',
      _ => '종방향 제어를 켜면 사용할 수 있는 기능: $names',
    };
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    child: _Banner(
      color: reason == 'unsupported' ? _muted : _warn,
      icon: reason == 'unsupported' ? Icons.block : Icons.speed,
      text: message(reason, features),
    ),
  );
}

class KovaSettingTile extends StatefulWidget {
  KovaSettingTile({
    required this.setting,
    required this.document,
    required this.controller,
  }) : super(key: ValueKey('kova-setting-${setting.key}'));

  final KovaParamSetting setting;
  final KovaParamsDocument document;
  final KovaParamsController controller;

  @override
  State<KovaSettingTile> createState() => _KovaSettingTileState();
}

class _KovaSettingTileState extends State<KovaSettingTile> {
  bool _expanded = false;
  double? _drag;
  late final TextEditingController _input = TextEditingController();
  String? _inputError;
  Object? _inputShownFor;

  KovaParamSetting get s => widget.setting;
  String? get _locale => widget.document.defaultLocale;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _change(Object? value) async {
    final reviewed = s;
    setState(() => _inputError = null);
    if (s.risk == KovaRisk.control) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) =>
            _ConfirmDialog(setting: s, value: value, locale: _locale),
      );
      if (confirmed != true || !mounted) return;
    }
    await widget.controller.setValue(
      reviewed.key,
      value,
      reviewedSetting: reviewed,
    );
    if (mounted) setState(() => _drag = null);
  }

  num _snap(double raw) {
    final min = s.minimum!;
    final step = s.step;
    var v = step == null ? raw : min + ((raw - min) / step).round() * step;
    v = v.clamp(min, s.maximum!).toDouble();
    if (s.type == KovaParamType.integer) return v.round();
    return double.parse(s.formatNumber(v));
  }

  void _submitInput() {
    final text = _input.text.trim();
    final parsed = s.type == KovaParamType.integer
        ? int.tryParse(text)
        : double.tryParse(text);
    if (parsed == null) {
      setState(() => _inputError = '숫자를 입력해 주세요.');
      return;
    }
    final error = s.check(parsed);
    if (error != null) {
      setState(() => _inputError = error);
      return;
    }
    _change(parsed);
  }

  Future<void> _openChoices(Object? current) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                s.title.resolve(defaultLocale: _locale),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
            // Long lists (e.g. 49 power-off times) scroll inside the sheet.
            Flexible(
              child: ListView(
                key: ValueKey('kova-options-${s.key}'),
                shrinkWrap: true,
                children: [
                  for (final option in s.options)
                    ListTile(
                      key: ValueKey('kova-option-${s.key}-${option.value}'),
                      title: Text(option.label(defaultLocale: _locale)),
                      trailing: option.matches(current)
                          ? const Icon(Icons.check_circle, color: _accent)
                          : null,
                      onTap: () => Navigator.of(context).pop(option.value),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null && !KovaParamOption(picked, null).matches(current)) {
      await _change(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final hasPending = controller.pending.containsKey(s.key);
    final shown = hasPending ? controller.pending[s.key] : s.value;
    final lock = controller.lockReasonFor(s);
    final editable = lock == null;
    final control = s.control;
    final description = s.description?.resolve(defaultLocale: _locale);
    final longDescription = description != null && description.length > 48;
    final notice = controller.notices[s.key];

    if ((control == KovaParamControl.slider ||
            control == KovaParamControl.numberField) &&
        _inputShownFor != s.value) {
      _inputShownFor = s.value;
      _input.text = s.value is num ? s.formatNumber(s.value as num) : '';
    }

    Widget? trailing;
    if (control == KovaParamControl.toggle) {
      trailing = Switch(
        key: ValueKey('kova-toggle-${s.key}'),
        value: s.isToggleOn(shown),
        onChanged: editable ? (v) => _change(s.toggleValue(v)) : null,
      );
    } else if (control != KovaParamControl.slider) {
      trailing = Text(
        s.describe(shown, defaultLocale: _locale),
        key: ValueKey('kova-value-${s.key}'),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: hasPending ? _muted : null,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  s.title.resolve(defaultLocale: _locale),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15.5,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description,
              maxLines: _expanded ? null : 2,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 13, height: 1.4),
            ),
          ],
          if (longDescription || _expanded)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('kova-more-${s.key}'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? '접기' : '자세히'),
              ),
            ),
          if (_expanded) _Details(setting: s, locale: _locale),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: _badges()),
          if (controller.status == KovaLinkStatus.connected &&
              const {
                'pendingParked',
                'pendingRestart',
                'applying',
              }.contains(s.applyState) &&
              s.appliedValue != null)
            _Line(
              color: _muted,
              text:
                  '저장값 ${s.describe(s.value, defaultLocale: _locale)} · '
                  '현재 적용값 ${s.describe(s.appliedValue, defaultLocale: _locale)}',
            ),
          if (controller.status == KovaLinkStatus.connected)
            for (final status in s.runtimeStates)
              _Line(
                icon: Icons.info_outline,
                color: status.state == 'active' ? _accent : _muted,
                text:
                    '${status.title.resolve(defaultLocale: _locale)} · '
                    '${switch (status.state) {
                      'off' => '끔',
                      'waiting' => '대기',
                      'awaitingAuthority' => '차량 제어 권한 대기',
                      'active' => '활성',
                      'paused' => '일시중지',
                      'manualRequired' => '수동 재개 필요',
                      'unsupported' => '이 차량에서 미지원',
                      _ => '확인 대기',
                    }}',
              ),
          if (controller.status == KovaLinkStatus.connected)
            for (final dependency in s.dependencies)
              if (dependency.state != 'met')
                _Line(
                  icon: Icons.info_outline,
                  color: _warn,
                  text:
                      '${dependency.title.resolve(defaultLocale: _locale)} · '
                      '${switch (dependency.state) {
                        'unmet' => '조건 필요',
                        'pendingRestart' => '다음 시동부터 적용',
                        'pendingConsumer' => '아직 차에서 동작 안 함',
                        'unsupported' => '이 차량에서 미지원',
                        _ => '확인 대기',
                      }}',
                ),
          if (control == KovaParamControl.slider) _slider(shown, editable),
          if (control == KovaParamControl.numberField) _numberField(editable),
          if (control == KovaParamControl.choice)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                key: ValueKey('kova-choice-${s.key}'),
                onPressed: editable ? () => _openChoices(shown) : null,
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('선택'),
              ),
            ),
          // Connection-wide locks are explained once on the connection card.
          if (lock != null &&
              !hasPending &&
              controller.writeLock == KovaWriteLock.none)
            _Line(
              key: ValueKey('kova-lock-${s.key}'),
              icon: Icons.lock_outline,
              color: _muted,
              text: lock,
            ),
          if (hasPending)
            _Line(
              key: ValueKey('kova-pending-${s.key}'),
              color: _warn,
              text: '보내는 중…',
              spinner: true,
            )
          else if (notice != null && notice.kind != KovaNoticeKind.sending)
            _Line(
              key: ValueKey('kova-notice-${s.key}'),
              icon: switch (notice.kind) {
                KovaNoticeKind.applied => Icons.check_circle_outline,
                KovaNoticeKind.rejected => Icons.block,
                KovaNoticeKind.conflict => Icons.sync_problem,
                _ => Icons.help_outline,
              },
              color: switch (notice.kind) {
                KovaNoticeKind.applied => _accent,
                KovaNoticeKind.rejected => _danger,
                _ => _warn,
              },
              text: notice.kind == KovaNoticeKind.rejected
                  ? '저장 안 됨 · ${notice.message}'
                  : notice.message,
            ),
        ],
      ),
    );
  }

  /// Only what changes how the user can act: when a change takes effect and
  /// whether the feature is still being prepared. Read-only, unsupported
  /// and control-risk items already say so in the lock line / confirm
  /// dialog.
  List<Widget> _badges() {
    if (s.status == KovaAvailability.unsupported) return [];
    // One badge: is the saved value what the car runs now, or when will it be?
    if (s.status == KovaAvailability.pendingConsumer) {
      return [
        _Badge(
          '아직 차에서 동작 안 함',
          _muted,
          key: ValueKey('kova-badge-pending-${s.key}'),
        ),
      ];
    }
    final connected = widget.controller.status == KovaLinkStatus.connected;
    final currentState = connected ? s.applyState : null;
    final needsCondition =
        connected &&
        s.value != s.defaultValue &&
        s.dependencies.any((dependency) => dependency.state != 'met');
    const later = Color(0xFF72A7FF);
    final policy = needsCondition
        ? ('저장됨 · 아래 조건이 맞아야 동작', _warn)
        : switch ((s.applyPolicy, currentState)) {
            (KovaApplyPolicy.immediate, 'applied') => ('바로 적용됨', _accent),
            (_, 'applied') => ('적용됨', _accent),
            (_, 'applying') => ('저장됨 · 적용 중', _muted),
            (_, 'pendingRestart') => ('저장됨 · 다음 시동부터 적용', _warn),
            (_, 'pendingParked') => ('저장됨 · P 정차 시 적용', _warn),
            (_, 'awaitingLongitudinal') => ('종방향 제어 적용 대기', _warn),
            (_, 'awaitingStart') => ('저장됨 · 다음 시동부터 적용', later),
            (KovaApplyPolicy.immediate, _) when connected => (
              '바로 적용됨',
              _accent,
            ),
            (KovaApplyPolicy.offroad, _) when !s.saveAnytime => (
              'P 정차 중 변경 · 다음 시동부터 적용',
              _warn,
            ),
            (KovaApplyPolicy.parked, _) => (
              s.saveAnytime ? 'P 정차 시 적용' : 'P 정차 중 변경',
              _warn,
            ),
            (KovaApplyPolicy.offroad || KovaApplyPolicy.restart, _) => (
              '다음 시동부터 적용',
              later,
            ),
            _ => null,
          };
    return [
      if (policy case (final text, final color))
        _Badge(text, color, key: ValueKey('kova-badge-policy-${s.key}')),
    ];
  }

  Widget _slider(Object? shown, bool editable) {
    final min = s.minimum!.toDouble();
    final max = s.maximum!.toDouble();
    final current = (_drag ?? (shown is num ? shown.toDouble() : min))
        .clamp(min, max)
        .toDouble();
    final step = s.step;
    final divisions = step != null && step > 0
        ? ((max - min) / step).round()
        : null;
    final unit = s.unit?.resolve(defaultLocale: _locale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              s.formatNumber(min),
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                key: ValueKey('kova-slider-${s.key}'),
                value: current,
                min: min,
                max: max,
                divisions:
                    divisions != null && divisions > 0 && divisions <= 1000
                    ? divisions
                    : null,
                label: s.describe(_snap(current), defaultLocale: _locale),
                onChanged: editable ? (v) => setState(() => _drag = v) : null,
                onChangeEnd: editable ? (v) => _change(_snap(v)) : null,
              ),
            ),
            Text(
              s.formatNumber(max),
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
        Row(
          children: [
            Text(
              '지금 ${s.describe(_drag != null ? _snap(_drag!) : shown, defaultLocale: _locale)}',
              key: ValueKey('kova-value-${s.key}'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            SizedBox(width: 132, child: _inputField(editable, unit)),
          ],
        ),
      ],
    );
  }

  Widget _numberField(bool editable) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: _inputField(editable, s.unit?.resolve(defaultLocale: _locale)),
  );

  Widget _inputField(bool editable, String? unit) => TextField(
    key: ValueKey('kova-input-${s.key}'),
    controller: _input,
    enabled: editable,
    keyboardType: TextInputType.numberWithOptions(
      decimal: s.type == KovaParamType.number,
      signed: (s.minimum ?? -1) < 0,
    ),
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _submitInput(),
    decoration: InputDecoration(
      isDense: true,
      suffixText: unit,
      errorText: _inputError,
      errorMaxLines: 2,
      suffixIcon: IconButton(
        key: ValueKey('kova-apply-${s.key}'),
        tooltip: '적용',
        icon: const Icon(Icons.check, size: 18),
        onPressed: editable ? _submitInput : null,
      ),
    ),
  );
}

class _Details extends StatelessWidget {
  const _Details({required this.setting, required this.locale});

  final KovaParamSetting setting;
  final String? locale;

  @override
  Widget build(BuildContext context) {
    final s = setting;
    final lines = <String>[
      '기본값: ${s.describe(s.defaultValue, defaultLocale: locale)}',
      if (s.hasRange)
        '범위: ${s.describe(s.minimum, defaultLocale: locale)} – ${s.describe(s.maximum, defaultLocale: locale)}',
      '적용: ${switch (s.applyPolicy) {
        KovaApplyPolicy.immediate => '바로 적용돼요.',
        KovaApplyPolicy.offroad => s.saveAnytime ? '언제든 값을 저장할 수 있어요.' : 'P에 두고 완전히 정차했을 때 바꿀 수 있고, 다음 시동부터 적용돼요.',
        KovaApplyPolicy.parked => s.saveAnytime ? '값은 언제든 저장할 수 있고, P에 두고 완전히 정차하면 반영돼요.' : 'P에 두고 완전히 정차했을 때 바꿀 수 있어요.',
        KovaApplyPolicy.restart => s.saveAnytime ? '언제든 저장할 수 있고, 다음 시동부터 적용돼요.' : 'P에 두고 완전히 정차했을 때 바꿀 수 있고, 다음 시동부터 적용돼요.',
        KovaApplyPolicy.unknown => '언제 적용되는지 알 수 없어 앱에서는 바꿀 수 없어요.',
      }}',
      if (s.applyState == 'pendingRestart' && s.appliedValue != null)
        '현재 적용값: ${s.describe(s.appliedValue, defaultLocale: locale)}',
      if (s.status == KovaAvailability.pendingConsumer)
        '상태: 아직 차에서 동작하지 않는 기능이에요. 값은 저장되지만 차 동작은 바뀌지 않아요.',
      if (s.requiredCapabilities.isNotEmpty)
        '필요 기능: ${s.requiredCapabilities.join(', ')}',
      '항목 키: ${s.key}',
    ];
    return Container(
      key: ValueKey('kova-details-${s.key}'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        lines.join('\n'),
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color, {super.key});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: 0.6)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.color,
    required this.text,
    this.icon,
    this.spinner = false,
    super.key,
  });

  final Color color;
  final String text;
  final IconData? icon;
  final bool spinner;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (spinner)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        else if (icon != null)
          Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12.5, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.setting,
    required this.value,
    required this.locale,
  });

  final KovaParamSetting setting;
  final Object? value;
  final String? locale;

  @override
  Widget build(BuildContext context) {
    final title = setting.title.resolve(defaultLocale: locale);
    return AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: _warn),
      title: const Text('주행에 영향을 주는 설정'),
      content: Text(
        '$title: ${setting.describe(value, defaultLocale: locale)}\n\n'
        '조향이나 속도 조절이 달라질 수 있어요.'
        '${setting.status == KovaAvailability.pendingConsumer ? '\n\n준비 중인 기능이라 값만 저장되고 실제 동작은 아직 바뀌지 않아요.' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('kova-confirm-change'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('바꾸기'),
        ),
      ],
    );
  }
}
