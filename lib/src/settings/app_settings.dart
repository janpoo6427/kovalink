import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/network/local_endpoint_policy.dart';
import 'package:kovalink/src/services/demo_drive_scenario.dart';

/// App chrome theme (설정 → 앱 테마). The road view keeps its own scene
/// theme ([SceneTheme], 맑음/흐림).
enum AppThemeMode { system, light, dark }

/// App-only settings. Nothing here is sent to the vehicle: there are no
/// actuation, engagement, safety or kovapilot developer switches, and the
/// app never writes vehicle Params.
@immutable
class AppSettings {
  const AppSettings({
    this.speedUnit = SpeedUnit.kph,
    this.viewpoint = SceneViewpoint.chase,
    this.sceneTheme = SceneTheme.clear,
    this.appTheme = AppThemeMode.dark,
    this.brightness = 1.0,
    this.showLanes = true,
    this.showObjects = true,
    this.showPath = true,
    this.showScenery = true,
    this.showHud = true,
    this.demoMode = true,
    this.demoRoute = DemoRoute.city,
    this.telemetryEndpoint = defaultTelemetryEndpoint,
    this.signalingEndpoint = defaultSignalingEndpoint,
    this.settingsEndpoint = defaultSettingsEndpoint,
    this.vehicleModelId,
    this.nativeVehicleOverlay = false,
    this.renderQuality = RenderQuality.auto,
  });

  static const schemaVersion = 1;
  static const defaultTelemetryEndpoint = 'ws://comma.local:8082/v1/telemetry';
  static const defaultSignalingEndpoint = 'http://comma.local:8082/v1/stream';

  /// kovapilot settings HTTP origin (`/v1/kova-params` is appended).
  static const defaultSettingsEndpoint = 'http://comma.local:8082';
  static const minBrightness = 0.4;

  final SpeedUnit speedUnit;
  final SceneViewpoint viewpoint;
  final SceneTheme sceneTheme;
  final AppThemeMode appTheme;

  /// Road-view brightness 0.4–1.0 (dims the scene for night driving).
  final double brightness;
  final bool showLanes;
  final bool showObjects;
  final bool showPath;
  final bool showScenery;
  final bool showHud;
  final bool demoMode;
  final DemoRoute demoRoute;
  final String telemetryEndpoint;
  final String signalingEndpoint;
  final String settingsEndpoint;

  /// Selected vehicle model pack id; null = default built-in.
  final String? vehicleModelId;

  /// Experimental: layer the pack GLB over the chase view (Android/iOS).
  final bool nativeVehicleOverlay;

  /// 화질: 자동 (GPU, 느리면 소프트웨어) / 고품질 (GPU) / 절약 (소프트웨어).
  final RenderQuality renderQuality;

  SceneLayers get layers => SceneLayers(
    lanes: showLanes,
    objects: showObjects,
    path: showPath,
    scenery: showScenery,
  );

  AppSettings copyWith({
    SpeedUnit? speedUnit,
    SceneViewpoint? viewpoint,
    SceneTheme? sceneTheme,
    AppThemeMode? appTheme,
    double? brightness,
    bool? showLanes,
    bool? showObjects,
    bool? showPath,
    bool? showScenery,
    bool? showHud,
    bool? demoMode,
    DemoRoute? demoRoute,
    String? telemetryEndpoint,
    String? signalingEndpoint,
    String? settingsEndpoint,
    String? vehicleModelId,
    bool clearVehicleModel = false,
    bool? nativeVehicleOverlay,
    RenderQuality? renderQuality,
  }) => AppSettings(
    speedUnit: speedUnit ?? this.speedUnit,
    viewpoint: viewpoint ?? this.viewpoint,
    sceneTheme: sceneTheme ?? this.sceneTheme,
    appTheme: appTheme ?? this.appTheme,
    brightness: _clampBrightness(brightness ?? this.brightness),
    showLanes: showLanes ?? this.showLanes,
    showObjects: showObjects ?? this.showObjects,
    showPath: showPath ?? this.showPath,
    showScenery: showScenery ?? this.showScenery,
    showHud: showHud ?? this.showHud,
    demoMode: demoMode ?? this.demoMode,
    demoRoute: demoRoute ?? this.demoRoute,
    telemetryEndpoint: telemetryEndpoint ?? this.telemetryEndpoint,
    signalingEndpoint: signalingEndpoint ?? this.signalingEndpoint,
    settingsEndpoint: settingsEndpoint ?? this.settingsEndpoint,
    vehicleModelId: clearVehicleModel
        ? null
        : vehicleModelId ?? this.vehicleModelId,
    nativeVehicleOverlay: nativeVehicleOverlay ?? this.nativeVehicleOverlay,
    renderQuality: renderQuality ?? this.renderQuality,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'speedUnit': speedUnit.name,
    'viewpoint': viewpoint.name,
    'sceneTheme': sceneTheme.name,
    'appTheme': appTheme.name,
    'brightness': brightness,
    'showLanes': showLanes,
    'showObjects': showObjects,
    'showPath': showPath,
    'showScenery': showScenery,
    'showHud': showHud,
    'demoMode': demoMode,
    'demoRoute': demoRoute.name,
    'telemetryEndpoint': telemetryEndpoint,
    'signalingEndpoint': signalingEndpoint,
    'settingsEndpoint': settingsEndpoint,
    'vehicleModelId': ?vehicleModelId,
    'nativeVehicleOverlay': nativeVehicleOverlay,
    'renderQuality': renderQuality.name,
  };

  /// Tolerant parser: each unknown or invalid field falls back to its
  /// default instead of discarding the whole file. Stored endpoints are
  /// re-checked against the local-only policy.
  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const defaults = AppSettings();
    T pick<T extends Enum>(List<T> values, String key, T fallback) {
      final name = json[key];
      return values.firstWhere(
        (value) => value.name == name,
        orElse: () => fallback,
      );
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    String endpoint(
      String key,
      String fallback,
      String? Function(String) validate,
    ) {
      final value = json[key];
      return value is String && validate(value) == null
          ? value.trim()
          : fallback;
    }

    final brightness = json['brightness'];
    final modelId = json['vehicleModelId'];
    return AppSettings(
      speedUnit: pick(SpeedUnit.values, 'speedUnit', defaults.speedUnit),
      viewpoint: pick(SceneViewpoint.values, 'viewpoint', defaults.viewpoint),
      sceneTheme: pick(SceneTheme.values, 'sceneTheme', defaults.sceneTheme),
      appTheme: pick(AppThemeMode.values, 'appTheme', defaults.appTheme),
      brightness: brightness is num && brightness.isFinite
          ? _clampBrightness(brightness.toDouble())
          : defaults.brightness,
      showLanes: flag('showLanes', defaults.showLanes),
      showObjects: flag('showObjects', defaults.showObjects),
      showPath: flag('showPath', defaults.showPath),
      showScenery: flag('showScenery', defaults.showScenery),
      showHud: flag('showHud', defaults.showHud),
      demoMode: flag('demoMode', defaults.demoMode),
      demoRoute: pick(DemoRoute.values, 'demoRoute', defaults.demoRoute),
      telemetryEndpoint: endpoint(
        'telemetryEndpoint',
        defaultTelemetryEndpoint,
        LocalEndpointPolicy.validate,
      ),
      signalingEndpoint: endpoint(
        'signalingEndpoint',
        defaultSignalingEndpoint,
        LocalEndpointPolicy.validateSignaling,
      ),
      settingsEndpoint: endpoint(
        'settingsEndpoint',
        defaultSettingsEndpoint,
        LocalEndpointPolicy.validateSettings,
      ),
      vehicleModelId:
          modelId is String &&
              RegExp(r'^[a-z0-9][a-z0-9-]{1,47}$').hasMatch(modelId)
          ? modelId
          : null,
      nativeVehicleOverlay: flag(
        'nativeVehicleOverlay',
        defaults.nativeVehicleOverlay,
      ),
      renderQuality: pick(
        RenderQuality.values,
        'renderQuality',
        defaults.renderQuality,
      ),
    );
  }

  static double _clampBrightness(double value) =>
      value.clamp(minBrightness, 1.0);

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

abstract class SettingsStore {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> json);
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.data]);

  Map<String, dynamic>? data;
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read() async => data;

  @override
  Future<void> write(Map<String, dynamic> json) async {
    writes++;
    data = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
  }
}

/// JSON file in the app's private support directory. Writes go to a temp
/// file first and are renamed so a crash never leaves a half-written file.
class FileSettingsStore implements SettingsStore {
  FileSettingsStore(this.directory);

  static const fileName = 'kovalink_settings.json';
  final Future<Directory> Function() directory;

  Future<File> _file() async => File('${(await directory()).path}/$fileName');

  @override
  Future<Map<String, dynamic>?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  @override
  Future<void> write(Map<String, dynamic> json) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      flush: true,
    );
    await temp.rename(file.path);
  }
}

class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.store,
    AppSettings initial = const AppSettings(),
  }) : _value = initial;

  final SettingsStore store;
  AppSettings _value;
  bool loaded = false;

  /// Last storage problem (shown in settings); the app keeps working with
  /// in-memory settings.
  String? storageError;
  Future<void> _pending = Future.value();

  AppSettings get value => _value;

  Future<void> load() async {
    try {
      final json = await store.read();
      if (json != null) _value = AppSettings.fromJson(json);
      storageError = null;
    } on Object catch (error) {
      storageError = '설정을 불러오지 못해 기본값을 씁니다: $error';
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> update(AppSettings Function(AppSettings current) change) {
    final next = change(_value);
    if (next == _value) return _pending;
    _value = next;
    notifyListeners();
    final snapshot = next.toJson();
    _pending = _pending.then((_) async {
      try {
        await store.write(snapshot);
        storageError = null;
      } on Object catch (error) {
        storageError = '설정을 저장하지 못했습니다: $error';
        notifyListeners();
      }
    });
    return _pending;
  }

  /// Saves the telemetry address only if the local-only policy accepts it.
  /// Returns the user-facing error otherwise.
  String? setTelemetryEndpoint(String endpoint) {
    final error = LocalEndpointPolicy.validate(endpoint);
    if (error == null) {
      update((s) => s.copyWith(telemetryEndpoint: endpoint.trim()));
    }
    return error;
  }

  String? setSignalingEndpoint(String endpoint) {
    final error = LocalEndpointPolicy.validateSignaling(endpoint);
    if (error == null) {
      update((s) => s.copyWith(signalingEndpoint: endpoint.trim()));
    }
    return error;
  }

  /// Saves the kovapilot settings origin under the same local-only policy.
  String? setSettingsEndpoint(String endpoint) {
    final error = LocalEndpointPolicy.validateSettings(endpoint);
    if (error == null) {
      update((s) => s.copyWith(settingsEndpoint: endpoint.trim()));
    }
    return error;
  }
}
