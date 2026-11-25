import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/kovapilot_git/kovapilot_version_screen.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/features/settings/kova_params_panel.dart';
import 'package:kovalink/src/features/settings/renderer_diagnostics_card.dart';
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
import 'package:kovalink/src/widgets/readable_width.dart';

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
    this.onTabSelected,
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

  /// Another tab was picked. The app replaces this page with that tab's
  /// route, so back from any tab goes to the drive screen. Null switches
  /// the tab in place (the screen used on its own, e.g. in tests).
  final ValueChanged<SettingsTab>? onTabSelected;

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

  void _select(SettingsTab tab) {
    if (tab == _tab) return;
    final open = widget.onTabSelected;
    if (open != null) {
      open(tab);
    } else {
      setState(() => _tab = tab);
    }
  }

  /// The found comma's settings address; null before one is found.
  String? get _settingsAddress => widget.settings?.value.settingsEndpoint;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final vehicleModel = widget.vehicleModel;
    final settings = widget.settings;
    final modelPicker = widget.modelPicker;
    return AnimatedBuilder(
      animation: Listenable.merge([
        controller.status,
        ?vehicleModel,
        ?settings,
        _kova,
      ]),
      builder: (context, _) => ReadableListView(
        children: [
          const PageHeader(title: '설정'),
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
                  label: _TabLabel('앱'),
                ),
                ButtonSegment(
                  value: SettingsTab.session,
                  icon: Icon(Icons.cable, size: 18),
                  label: _TabLabel('연결 상태'),
                ),
                ButtonSegment(
                  value: SettingsTab.kovapilot,
                  icon: Icon(Icons.directions_car_outlined, size: 18),
                  label: _TabLabel('kovapilot'),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => _select(s.first),
            ),
          ),
          const SizedBox(height: 6),
          if (_tab == SettingsTab.kovapilot) ...[
            const SizedBox(height: 10),
            KovapilotVersionEntry(
              endpoint: _kova.endpoint ?? _settingsAddress,
              sessionFor: _kova.sessionFor,
            ),
            KovaParamsPanel(
              controller: _kova,
              address: _settingsAddress,
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
            _AutoConnectSection(settings: settings),
            if (widget.library != null)
              _VehicleModelSection(
                settings: settings,
                library: widget.library!,
                current:
                    vehicleModel?.value ??
                    VehicleModelLoadResult.bundledDefault,
                picker: modelPicker,
              ),
            const DiagnosticsEntry(),
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
        ],
      ),
    );
  }
}

/// Tab label that shrinks to fit a narrow phone instead of wrapping.
class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

const _noComma = '아직 찾은 콤마가 없어요';

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
      GatewayMode.demo => '데모 주행 중',
      GatewayMode.connecting => '연결 중',
      GatewayMode.live => '연결됨',
      GatewayMode.disconnected => '연결 안 됨',
      GatewayMode.error => '연결 끊김',
    };
    final kovaStatus = switch (kova.status) {
      KovaLinkStatus.disconnected => '연결 안 됨',
      KovaLinkStatus.connecting => '연결 중',
      KovaLinkStatus.connected => '연결됨',
      KovaLinkStatus.stale => '다시 연결하는 중',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Card(
          key: const ValueKey('session-card'),
          child: Column(
            children: [
              _StatusTile(
                icon: Icons.speed_outlined,
                title: '주행 정보',
                status: telemetry,
                address:
                    controller.connectedEndpoint ??
                    settings?.value.telemetryEndpoint ??
                    _noComma,
              ),
              const Divider(height: 1, indent: 56),
              _StatusTile(
                icon: Icons.videocam_outlined,
                title: '카메라',
                status: '볼 때만 연결돼요',
                address: settings?.value.signalingEndpoint ?? _noComma,
              ),
              const Divider(height: 1, indent: 56),
              _StatusTile(
                icon: Icons.tune_outlined,
                title: 'kovapilot 설정',
                status: kovaStatus,
                address:
                    kova.endpoint ??
                    settings?.value.settingsEndpoint ??
                    _noComma,
              ),
              const Divider(height: 1, indent: 56),
              _StatusTile(
                icon:
                    controller.gatewayAuthenticated ||
                        settings?.value.registeredComma != null
                    ? Icons.verified_user_outlined
                    : Icons.no_encryption_gmailerrorred_outlined,
                title: '기기 등록',
                status: controller.gatewayAuthenticated
                    ? '등록됨 · 연결 토큰 확인됨'
                    : settings?.value.registeredComma != null
                    ? '등록됨'
                    : '아직 등록 전이에요',
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            '주소는 자동 연결이 찾은 콤마에 맞춰져요.',
            style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// One connection line: status, with the address small underneath.
class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.status,
    this.address,
  });

  final IconData icon;
  final String title;
  final String status;
  final String? address;

  @override
  Widget build(BuildContext context) {
    final address = this.address;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status),
          if (address != null)
            Text(
              address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF8E9DA9), fontSize: 11.5),
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
      bool current,
      AppSettings Function(AppSettings, bool) apply,
    ) => SwitchListTile(
      key: ValueKey('setting-$key'),
      title: Text(title),
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
                value.showLanes,
                (s, on) => s.copyWith(showLanes: on),
              ),
              toggle(
                'objects',
                '주변 차량',
                value.showObjects,
                (s, on) => s.copyWith(showObjects: on),
              ),
              toggle(
                'path',
                '주행 경로',
                value.showPath,
                (s, on) => s.copyWith(showPath: on),
              ),
              toggle(
                'scenery',
                '나무와 건물',
                value.showScenery,
                (s, on) => s.copyWith(showScenery: on),
              ),
              toggle(
                'hud',
                '속도와 제한속도',
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
                subtitle: live
                    ? const Text('차에 연결된 동안에는 데모가 나오지 않아요.')
                    : const Text('차 없이 예시 주행을 보여 줘요.'),
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

class _AutoConnectSection extends StatelessWidget {
  const _AutoConnectSection({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('자동 연결'),
        Card(
          child: SwitchListTile(
            key: const ValueKey('setting-auto-connect'),
            title: const Text('콤마 자동으로 찾기'),
            subtitle: const Text('같은 와이파이나 핫스팟에 있는 콤마를 찾아서 연결해요.'),
            value: settings.value.autoConnect,
            onChanged: (on) =>
                settings.update((s) => s.copyWith(autoConnect: on)),
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
        title: const Text('이 모델을 지울까요?'),
        content: Text(entry.manifest.displayName),
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
                        '${entry.builtIn ? '기본 모델' : '가져온 모델'} · ${entry.manifest.license ?? '라이선스 없음'}',
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
                    title: const Text('모델 파일 가져오기'),
                    subtitle: const Text('.kovamodel 파일'),
                    onTap: _import,
                  ),
                  SwitchListTile(
                    key: const ValueKey('setting-native-overlay'),
                    title: const Text('3D 차량 모델 쓰기'),
                    subtitle: const Text('시험 중인 기능이에요. 휴대폰 앱의 뒤 시점에서만 보여요.'),
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
                    manifest.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '길이 ${meters(dimensions.length)} m   폭 ${meters(dimensions.width)} m'
              '   높이 ${meters(dimensions.height)} m'
              '   축간거리 ${meters(dimensions.wheelbase)} m',
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
