import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/widgets/page_header.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.controller,
    this.vehicleModel,
    this.settings,
    this.library,
    this.modelPicker = pickModelFileWithSystemPicker,
    super.key,
  });

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;

  /// App settings. Null shows only the read-only vehicle sections (used by
  /// older callers and tests).
  final SettingsController? settings;
  final VehicleModelLibrary? library;
  final ModelFilePicker modelPicker;

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    return AnimatedBuilder(
      animation: Listenable.merge([controller, ?vehicleModel, ?settings]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 64, 20, 32),
        children: [
          const PageHeader(
            title: '설정',
            subtitle: '앱 화면과 동작만 바꿉니다. 차량 제어·안전 설정은 앱에서 바꿀 수 없습니다.',
          ),
          const SizedBox(height: 22),
          if (settings != null) ...[
            _DisplaySection(settings: settings),
            _LayerSection(settings: settings),
            _DemoSection(settings: settings, controller: controller),
            _EndpointSection(settings: settings),
            if (library != null)
              _VehicleModelSection(
                settings: settings,
                library: library!,
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
          const SizedBox(height: 6),
          const _SectionTitle('차량 설정 (gateway)'),
          if (!controller.canEditSettings)
            const Card(
              color: Color(0xFF17202A),
              child: ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text(
                  '설정 변경 잠김',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('인증된 gateway 연결 후 안전한 설정만 활성화됩니다.'),
              ),
            ),
          _SettingSection(
            title: '주행 화면',
            enabled: controller.canEditSettings,
            items: const [
              _SettingItem(
                '기본 로드뷰',
                '3D semantic scene',
                Icons.view_in_ar_outlined,
              ),
              _SettingItem('Telemetry rate', '10 Hz', Icons.speed_outlined),
              _SettingItem('카메라 자동 시작', '사용 안 함', Icons.videocam_off_outlined),
            ],
          ),
          const _SettingSection(
            title: '개인정보',
            enabled: false,
            items: [
              _SettingItem(
                'Comma Connect',
                '소스 정책으로 비활성화',
                Icons.cloud_off_outlined,
              ),
              _SettingItem(
                'Route upload',
                '소스 정책으로 비활성화',
                Icons.upload_file_outlined,
              ),
            ],
          ),
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
                ],
                onChanged: (v) =>
                    settings.update((s) => s.copyWith(sceneTheme: v)),
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
  String? telemetryError;
  String? signalingError;
  String? saved;

  @override
  void dispose() {
    telemetry.dispose();
    signaling.dispose();
    super.dispose();
  }

  void _save() {
    setState(() {
      telemetryError = widget.settings.setTelemetryEndpoint(telemetry.text);
      signalingError = widget.settings.setSignalingEndpoint(signaling.text);
      saved = telemetryError == null && signalingError == null
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

class _SettingSection extends StatelessWidget {
  const _SettingSection({
    required this.title,
    required this.enabled,
    required this.items,
  });
  final String title;
  final bool enabled;
  final List<_SettingItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF8E9DA9),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(
            child: Column(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  ListTile(
                    enabled: enabled,
                    leading: Icon(items[index].icon),
                    title: Text(items[index].label),
                    subtitle: Text(items[index].value),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                  if (index != items.length - 1)
                    const Divider(height: 1, indent: 56),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingItem {
  const _SettingItem(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}
