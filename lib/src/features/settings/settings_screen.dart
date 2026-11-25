import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/kova_params_panel.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/widgets/page_header.dart';

/// Which settings the screen shows. They live in different places and are
/// never mixed: the app's own settings (this phone), the current gateway
/// session (gone when disconnected) and kovapilot's settings (stored on the
/// device, drawn from its kova_params document).
enum SettingsTab { app, session, kovapilot }

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.controller,
    this.vehicleModel,
    this.settings,
    this.library,
    this.modelPicker = pickModelFileWithSystemPicker,
    this.kovaParams,
    this.initialTab = SettingsTab.app,
    this.now,
    super.key,
  });

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;

  /// App settings. Null shows only the read-only vehicle sections (used by
  /// older callers and tests).
  final SettingsController? settings;
  final VehicleModelLibrary? library;
  final ModelFilePicker modelPicker;

  /// kovapilot settings connection. Null = the screen owns one (no network
  /// until the user taps 연결).
  final KovaParamsController? kovaParams;
  final SettingsTab initialTab;

  /// Clock for "n초 전" labels (captures).
  final DateTime Function()? now;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsTab _tab = widget.initialTab;
  KovaParamsController? _ownedKova;

  KovaParamsController get _kova =>
      widget.kovaParams ?? (_ownedKova ??= KovaParamsController());

  @override
  void dispose() {
    _ownedKova?.dispose();
    super.dispose();
  }

  String get _settingsAddress =>
      widget.settings?.value.settingsEndpoint ??
      AppSettings.defaultSettingsEndpoint;

  Future<void> _editSettingsAddress() async {
    final settings = widget.settings;
    if (settings == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _SettingsAddressDialog(settings: settings),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final vehicleModel = widget.vehicleModel;
    final settings = widget.settings;
    final modelPicker = widget.modelPicker;
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        ?vehicleModel,
        ?settings,
        _kova,
      ]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 64, 20, 32),
        children: [
          const PageHeader(
            title: '설정',
            subtitle:
                '앱 설정은 이 휴대폰에, kovapilot 설정은 차에 저장돼요. 차량 제어 명령·안전 설정은 앱에서 바꿀 수 없습니다.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<SettingsTab>(
              key: const ValueKey('settings-tabs'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: SettingsTab.app,
                  icon: Icon(Icons.phone_iphone, size: 18),
                  label: Text('앱'),
                ),
                ButtonSegment(
                  value: SettingsTab.session,
                  icon: Icon(Icons.cable, size: 18),
                  label: Text('연결 세션'),
                ),
                ButtonSegment(
                  value: SettingsTab.kovapilot,
                  icon: Icon(Icons.directions_car_outlined, size: 18),
                  label: Text('kovapilot'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              switch (_tab) {
                SettingsTab.app => '이 휴대폰에만 저장돼요. 장치가 없어도 바꿀 수 있어요.',
                SettingsTab.session =>
                  '지금 연결에만 쓰여요. 연결이 끊기면 사라지고 차에는 저장되지 않아요.',
                SettingsTab.kovapilot =>
                  '차(kovapilot)에 저장돼요. 장치가 확인해 준 값만 보여요.',
              },
              key: const ValueKey('settings-tab-caption'),
              style: const TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
          if (_tab == SettingsTab.kovapilot) ...[
            const SizedBox(height: 10),
            KovaParamsPanel(
              controller: _kova,
              address: _settingsAddress,
              onEditAddress: settings == null ? null : _editSettingsAddress,
              now: widget.now,
            ),
          ] else if (_tab == SettingsTab.session)
            _SessionSection(
              controller: controller,
              settings: settings,
              kova: _kova,
            )
          else if (settings != null) ...[
            _DisplaySection(settings: settings),
            _LayerSection(settings: settings),
            _DemoSection(settings: settings, controller: controller),
            _EndpointSection(settings: settings),
            if (widget.library != null)
              _VehicleModelSection(
                settings: settings,
                library: widget.library!,
                current:
                    vehicleModel?.value ??
                    VehicleModelLoadResult.bundledDefault,
                picker: modelPicker,
              ),
            if (settings.storageError case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error,
                  style: const TextStyle(
                    color: Color(0xFFFFC857),
                    fontSize: 12,
                  ),
                ),
              ),
          ] else
            VehicleModelCard(
              result:
                  vehicleModel?.value ?? VehicleModelLoadResult.bundledDefault,
            ),
          if (_tab == SettingsTab.app)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                'Safety parameter, cloud privacy policy, 차량 actuation은 앱에서 변경할 수 없습니다.',
                style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Current gateway session facts. Nothing here is stored on the car.
class _SessionSection extends StatelessWidget {
  const _SessionSection({
    required this.controller,
    required this.settings,
    required this.kova,
  });

  final GatewayController controller;
  final SettingsController? settings;
  final KovaParamsController kova;

  @override
  Widget build(BuildContext context) {
    final telemetry = switch (controller.mode) {
      GatewayMode.demo => '데모 주행 중 (네트워크 안 씀)',
      GatewayMode.connecting => '연결 중',
      GatewayMode.live => '받는 중',
      GatewayMode.disconnected => '연결 안 됨',
      GatewayMode.error => '끊김',
    };
    final kovaStatus = switch (kova.status) {
      KovaLinkStatus.disconnected => '연결 안 됨',
      KovaLinkStatus.connecting => '연결 중',
      KovaLinkStatus.connected => '연결됨',
      KovaLinkStatus.stale => '오래됨 · 다시 연결 중',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('지금 연결'),
        Card(
          key: const ValueKey('session-card'),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.speed_outlined),
                title: const Text('주행 정보(telemetry)'),
                subtitle: Text(
                  '$telemetry · ${controller.connectedEndpoint ?? settings?.value.telemetryEndpoint ?? AppSettings.defaultTelemetryEndpoint}',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('카메라 보기'),
                subtitle: Text(
                  '보는 동안만 연결 · ${settings?.value.signalingEndpoint ?? AppSettings.defaultSignalingEndpoint}',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('kovapilot 설정 연결'),
                subtitle: Text(
                  '$kovaStatus · ${kova.endpoint ?? settings?.value.settingsEndpoint ?? AppSettings.defaultSettingsEndpoint}',
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: Icon(
                  controller.gatewayAuthenticated
                      ? Icons.verified_user_outlined
                      : Icons.no_encryption_gmailerrorred_outlined,
                ),
                title: const Text('장치 인증'),
                subtitle: Text(
                  controller.gatewayAuthenticated
                      ? '인증됨'
                      : 'pairing 전 · LAN 주소에서는 kovapilot 설정을 읽기만 해요',
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            '연결 주소는 「앱」 탭의 「연결 장치 주소」에서 바꿉니다. 이 탭의 내용은 차에 저장되지 않아요.',
            style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _SettingsAddressDialog extends StatefulWidget {
  const _SettingsAddressDialog({required this.settings});

  final SettingsController settings;

  @override
  State<_SettingsAddressDialog> createState() => _SettingsAddressDialogState();
}

class _SettingsAddressDialogState extends State<_SettingsAddressDialog> {
  late final text = TextEditingController(
    text: widget.settings.value.settingsEndpoint,
  );
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('kovapilot 설정 주소'),
    content: TextField(
      key: const ValueKey('kova-address-field'),
      controller: text,
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: InputDecoration(
        hintText: AppSettings.defaultSettingsEndpoint,
        helperText: '같은 기기 개발용: http://127.0.0.1:8082',
        errorText: error,
        errorMaxLines: 3,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('kova-address-save'),
        onPressed: () {
          final result = widget.settings.setSettingsEndpoint(text.text);
          if (result == null) {
            Navigator.of(context).pop();
          } else {
            setState(() => error = result);
          }
        },
        child: const Text('저장'),
      ),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8, top: 18),
    child: Text(
      title,
      style: const TextStyle(
        color: Color(0xFF8E9DA9),
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            showSelectedIcon: false,
            segments: [
              for (final (option, text) in options)
                ButtonSegment<T>(
                  value: option,
                  label: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            selected: {value},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ),
      ],
    ),
  );
}

class _DisplaySection extends StatelessWidget {
  const _DisplaySection({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final value = settings.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('주행 화면'),
        Card(
          child: Column(
            children: [
              _Choice<SceneViewpoint>(
                key: const ValueKey('setting-viewpoint'),
                label: '시점',
                value: value.viewpoint,
                options: const [
                  (SceneViewpoint.chase, '뒤'),
                  (SceneViewpoint.topDown, '위'),
                  (SceneViewpoint.driver, '운전석'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(viewpoint: v)),
              ),
              _Choice<SceneTheme>(
                key: const ValueKey('setting-scene-theme'),
                label: '도로 테마',
                value: value.sceneTheme,
                options: const [
                  (SceneTheme.clear, '맑음'),
                  (SceneTheme.overcast, '흐림'),
                  (SceneTheme.sunset, '노을'),
                  (SceneTheme.night, '밤'),
                  (SceneTheme.rain, '비'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(sceneTheme: v)),
              ),
              _Choice<RenderQuality>(
                key: const ValueKey('setting-render-quality'),
                label: '화질',
                value: value.renderQuality,
                options: const [
                  (RenderQuality.auto, '자동'),
                  (RenderQuality.high, '고품질'),
                  (RenderQuality.saver, '절약'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(renderQuality: v)),
              ),
              _Choice<SpeedUnit>(
                key: const ValueKey('setting-unit'),
                label: '속도 단위',
                value: value.speedUnit,
                options: const [
                  (SpeedUnit.kph, 'km/h'),
                  (SpeedUnit.mph, 'mph'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(speedUnit: v)),
              ),
              _Choice<AppThemeMode>(
                key: const ValueKey('setting-app-theme'),
                label: '앱 테마',
                value: value.appTheme,
                options: const [
                  (AppThemeMode.system, '시스템'),
                  (AppThemeMode.light, '밝게'),
                  (AppThemeMode.dark, '어둡게'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(appTheme: v)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.brightness_6_outlined, size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      '화면 밝기',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('setting-brightness'),
                        value: value.brightness,
                        min: AppSettings.minBrightness,
                        divisions: 6,
                        label: '${(value.brightness * 100).round()}%',
                        onChanged: (v) =>
                            settings.update((s) => s.copyWith(brightness: v)),
                      ),
                    ),
                    Text('${(value.brightness * 100).round()}%'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LayerSection extends StatelessWidget {
  const _LayerSection({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final value = settings.value;
    Widget toggle(
      String key,
      String title,
      String subtitle,
      bool current,
      AppSettings Function(AppSettings, bool) apply,
    ) => SwitchListTile(
      key: ValueKey('setting-$key'),
      title: Text(title),
      subtitle: Text(subtitle),
      value: current,
      onChanged: (on) => settings.update((s) => apply(s, on)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('표시 항목'),
        Card(
          child: Column(
            children: [
              toggle(
                'lanes',
                '차선',
                '흰 차선·노란 중앙선·가장자리',
                value.showLanes,
                (s, on) => s.copyWith(showLanes: on),
              ),
              toggle(
                'objects',
                '주변 차량',
                '선행차·주변 차·라바콘',
                value.showObjects,
                (s, on) => s.copyWith(showObjects: on),
              ),
              toggle(
                'path',
                '경로',
                '자차 앞 경로 띠',
                value.showPath,
                (s, on) => s.copyWith(showPath: on),
              ),
              toggle(
                'scenery',
                '배경',
                '나무·건물',
                value.showScenery,
                (s, on) => s.copyWith(showScenery: on),
              ),
              toggle(
                'hud',
                'HUD 수치',
                '속도·설정 속도·제한속도·안내 카드',
                value.showHud,
                (s, on) => s.copyWith(showHud: on),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DemoSection extends StatelessWidget {
  const _DemoSection({required this.settings, required this.controller});

  final SettingsController settings;
  final GatewayController controller;

  @override
  Widget build(BuildContext context) {
    final value = settings.value;
    final live =
        controller.mode == GatewayMode.live ||
        controller.mode == GatewayMode.connecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('데모'),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                key: const ValueKey('setting-demo'),
                title: const Text('데모 모드'),
                subtitle: Text(
                  live
                      ? '장치에 연결되어 있는 동안에는 데모를 켜지 않습니다.'
                      : '네트워크 없이 앱 안의 가짜 주행을 보여 줍니다.',
                ),
                value: value.demoMode,
                onChanged: (on) =>
                    settings.update((s) => s.copyWith(demoMode: on)),
              ),
              _Choice<DemoRoute>(
                key: const ValueKey('setting-demo-route'),
                label: '데모 경로',
                value: value.demoRoute,
                options: const [
                  (DemoRoute.city, '도심'),
                  (DemoRoute.highway, '고속도로'),
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(demoRoute: v)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
    );
  }
}

class _EndpointSection extends StatefulWidget {
  const _EndpointSection({required this.settings});

  final SettingsController settings;

  @override
  State<_EndpointSection> createState() => _EndpointSectionState();
}

class _EndpointSectionState extends State<_EndpointSection> {
  late final telemetry = TextEditingController(
    text: widget.settings.value.telemetryEndpoint,
  );
  late final signaling = TextEditingController(
    text: widget.settings.value.signalingEndpoint,
  );
  late final settingsAddress = TextEditingController(
    text: widget.settings.value.settingsEndpoint,
  );
  String? telemetryError;
  String? signalingError;
  String? settingsError;
  String? saved;

  @override
  void dispose() {
    telemetry.dispose();
    signaling.dispose();
    settingsAddress.dispose();
    super.dispose();
  }

  void _save() {
    setState(() {
      telemetryError = widget.settings.setTelemetryEndpoint(telemetry.text);
      signalingError = widget.settings.setSignalingEndpoint(signaling.text);
      settingsError = widget.settings.setSettingsEndpoint(settingsAddress.text);
      saved =
          telemetryError == null &&
              signalingError == null &&
              settingsError == null
          ? '저장했습니다.'
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('연결 장치 주소'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('setting-telemetry-endpoint'),
                  controller: telemetry,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Telemetry WebSocket',
                    hintText: AppSettings.defaultTelemetryEndpoint,
                    errorText: telemetryError,
                    errorMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('setting-signaling-endpoint'),
                  controller: signaling,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Camera signaling',
                    hintText: AppSettings.defaultSignalingEndpoint,
                    errorText: signalingError,
                    errorMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('setting-settings-endpoint'),
                  controller: settingsAddress,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'kovapilot 설정 (HTTP)',
                    hintText: AppSettings.defaultSettingsEndpoint,
                    errorText: settingsError,
                    errorMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        saved ??
                            '로컬 주소만 저장합니다(localhost, .local, 사설 IP). 공개 도메인은 거부합니다.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF8E9DA9),
                        ),
                      ),
                    ),
                    FilledButton(
                      key: const ValueKey('setting-endpoint-save'),
                      onPressed: _save,
                      child: const Text('저장'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _VehicleModelSection extends StatefulWidget {
  const _VehicleModelSection({
    required this.settings,
    required this.library,
    required this.current,
    required this.picker,
  });

  final SettingsController settings;
  final VehicleModelLibrary library;
  final VehicleModelLoadResult current;
  final ModelFilePicker picker;

  @override
  State<_VehicleModelSection> createState() => _VehicleModelSectionState();
}

class _VehicleModelSectionState extends State<_VehicleModelSection> {
  List<VehicleModelEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    widget.library.revision.addListener(_refresh);
    widget.library.list().then((entries) {
      if (mounted) setState(() => _entries = entries);
    });
  }

  @override
  void dispose() {
    widget.library.revision.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _entries = widget.library.cachedEntries);
  }

  Future<void> _import() async {
    await VehicleModelImportFlow.run(
      context,
      library: widget.library,
      settings: widget.settings,
      picker: widget.picker,
    );
  }

  Future<void> _delete(VehicleModelEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('차량 모델 삭제'),
        content: Text('${entry.manifest.displayName}을(를) 앱에서 지웁니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('model-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.library.delete(entry.id);
    if (widget.settings.value.vehicleModelId == entry.id) {
      await widget.settings.update((s) => s.copyWith(clearVehicleModel: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected =
        widget.settings.value.vehicleModelId ??
        VehicleModelLibrary.defaultModelId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('차량 모델'),
        VehicleModelCard(result: widget.current),
        Card(
          child: Builder(
            builder: (context) {
              final list = _entries;
              return Column(
                children: [
                  for (final entry in list)
                    ListTile(
                      key: ValueKey('model-${entry.id}'),
                      leading: SizedBox(
                        width: 72,
                        height: 48,
                        child: VehicleModelPreview(entry: entry),
                      ),
                      title: Text(entry.manifest.displayName),
                      subtitle: Text(
                        '${entry.builtIn ? '내장' : '가져옴'} · ${entry.manifest.license ?? '라이선스 미기재'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: entry.id == selected,
                      onTap: () => widget.settings.update(
                        (s) => s.copyWith(vehicleModelId: entry.id),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (entry.id == selected)
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xFF58F2C2),
                            ),
                          if (!entry.builtIn)
                            IconButton(
                              key: ValueKey('model-delete-${entry.id}'),
                              tooltip: '삭제',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(entry),
                            ),
                        ],
                      ),
                    ),
                  const Divider(height: 1),
                  ListTile(
                    key: const ValueKey('model-import'),
                    leading: const Icon(Icons.file_download_outlined),
                    title: const Text('파일 가져오기'),
                    subtitle: const Text(
                      '.kovamodel (ZIP: vehicle.json + GLB + LICENSE)',
                    ),
                    onTap: _import,
                  ),
                  SwitchListTile(
                    key: const ValueKey('setting-native-overlay'),
                    title: const Text('GLB 3D 모델 겹치기 (실험)'),
                    subtitle: const Text(
                      'Android/iOS에서 모델 팩의 GLB를 뒤 시점 위에 겹칩니다.',
                    ),
                    value: widget.settings.value.nativeVehicleOverlay,
                    onChanged: (on) => widget.settings.update(
                      (s) => s.copyWith(nativeVehicleOverlay: on),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Small preview: the pack's preview.png if present, otherwise the built-in
/// renderer drawing the pack's size and paint.
class VehicleModelPreview extends StatelessWidget {
  const VehicleModelPreview({required this.entry, super.key});

  final VehicleModelEntry entry;

  @override
  Widget build(BuildContext context) {
    final preview = entry.previewPath;
    if (preview != null && !kIsWeb) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(preview), fit: BoxFit.cover),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CustomPaint(
        painter: RoadWorldPainter(
          scene: RoadScene.idle,
          vehicle: EgoVehicleProfile.fromManifest(entry.manifest),
          theme: SceneTheme.overcast,
          layers: const SceneLayers(scenery: false),
          viewpoint: SceneViewpoint.chase,
        ),
      ),
    );
  }
}

class VehicleModelCard extends StatelessWidget {
  const VehicleModelCard({required this.result, super.key});

  final VehicleModelLoadResult result;

  @override
  Widget build(BuildContext context) {
    final manifest = result.manifest;
    final dimensions = result.profile.dimensions;
    String meters(double value) => value.toStringAsFixed(2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Color(manifest.appearance.paintArgb),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '내 차 모델 · ${manifest.displayName}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '길이 ${meters(dimensions.length)} m · 폭 ${meters(dimensions.width)} m'
              ' · 높이 ${meters(dimensions.height)} m'
              ' · 축간 ${meters(dimensions.wheelbase)} m',
              style: const TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              result.usesBuiltInModel
                  ? '표시 방식: 기본 내장 모델(2D)'
                  : '표시 방식: 모델 팩 GLB + 기본 내장 모델',
              style: const TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
            for (final warning in result.warnings) ...[
              const SizedBox(height: 6),
              Text(
                warning,
                style: const TextStyle(color: Color(0xFFFFC857), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
