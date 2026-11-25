import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/network/comma_registry.dart';
import 'package:kovalink/src/network/kovapilot_endpoints.dart';
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
    this.vehicleModelId,
    this.nativeVehicleOverlay = false,
    this.renderQuality = RenderQuality.auto,
    this.autoConnect = true,
    this.lastDeviceEndpoint,
    this.registeredComma,
  });

  static const schemaVersion = 1;

  /// Address fields older versions saved. They are ignored when read and
  /// dropped from the file ([SettingsController.load] writes it again).
  static const legacyEndpointKeys = [
    'telemetryEndpoint',
    'signalingEndpoint',
    'settingsEndpoint',
  ];
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

  /// Every kovapilot address, from the comma found or entered last
  /// ([lastDeviceEndpoint]); null until there is one. Not editable.
  KovapilotEndpoints? get endpoints =>
      KovapilotEndpoints.fromOrigin(lastDeviceEndpoint);
  String? get telemetryEndpoint => endpoints?.telemetry;
  String? get signalingEndpoint => endpoints?.signaling;
  String? get settingsEndpoint => endpoints?.settings;

  /// Selected vehicle model pack id; null = default built-in.
  final String? vehicleModelId;

  /// Experimental: layer the pack GLB over the chase view (Android/iOS).
  final bool nativeVehicleOverlay;

  /// 화질: 자동 (GPU, 느리면 소프트웨어) / 고품질 (GPU) / 절약 (소프트웨어).
  final RenderQuality renderQuality;

  /// 자동 연결: look for the kovapilot device on the phone's Wi-Fi /
  /// hotspot until it answers (on by default).
  final bool autoConnect;

  /// Settings origin of the last device connected (tried first next time;
  /// every address follows it): `https://<IP>:8082` for a comma on Wi-Fi.
  /// Only the app sets it, under the local-only policy.
  final String? lastDeviceEndpoint;

  /// The comma registered on this phone: certificate pin and last address.
  /// Its token is in the phone's secure storage, never here.
  final RegisteredComma? registeredComma;

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
    String? vehicleModelId,
    bool clearVehicleModel = false,
    bool? nativeVehicleOverlay,
    RenderQuality? renderQuality,
    bool? autoConnect,
    String? lastDeviceEndpoint,
    RegisteredComma? registeredComma,
    bool clearRegisteredComma = false,
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
    vehicleModelId: clearVehicleModel
        ? null
        : vehicleModelId ?? this.vehicleModelId,
    nativeVehicleOverlay: nativeVehicleOverlay ?? this.nativeVehicleOverlay,
    renderQuality: renderQuality ?? this.renderQuality,
    autoConnect: autoConnect ?? this.autoConnect,
    lastDeviceEndpoint: lastDeviceEndpoint ?? this.lastDeviceEndpoint,
    registeredComma: clearRegisteredComma
        ? null
        : registeredComma ?? this.registeredComma,
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
    'vehicleModelId': ?vehicleModelId,
    'nativeVehicleOverlay': nativeVehicleOverlay,
    'renderQuality': renderQuality.name,
    'autoConnect': autoConnect,
    'lastDeviceEndpoint': ?lastDeviceEndpoint,
    'registeredComma': ?registeredComma?.toJson(),
  };

  /// Tolerant parser: each unknown or invalid field falls back to its
  /// default instead of discarding the whole file. The stored device
  /// address is re-checked against the local-only policy; addresses saved
  /// by older versions ([legacyEndpointKeys]) are ignored.
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

    final brightness = json['brightness'];
    final modelId = json['vehicleModelId'];
    final lastDevice = json['lastDeviceEndpoint'];
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
      autoConnect: flag('autoConnect', defaults.autoConnect),
      lastDeviceEndpoint:
          lastDevice is String &&
              LocalEndpointPolicy.validateSettings(lastDevice) == null
          ? lastDevice.trim()
          : null,
      registeredComma: RegisteredComma.fromJson(json['registeredComma']),
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
      if (json != null) {
        _value = AppSettings.fromJson(json);
        // Addresses typed into older versions are not used any more; take
        // them out of the file too.
        if (AppSettings.legacyEndpointKeys.any(json.containsKey)) {
          _write(_value.toJson());
        }
      }
      storageError = null;
    } on Object {
      storageError = '저장된 설정을 불러오지 못해 기본값으로 시작했어요.';
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> update(AppSettings Function(AppSettings current) change) {
    final next = change(_value);
    if (next == _value) return _pending;
    _value = next;
    notifyListeners();
    return _write(next.toJson());
  }

  Future<void> _write(Map<String, dynamic> snapshot) {
    _pending = _pending.then((_) async {
      try {
        await store.write(snapshot);
        storageError = null;
      } on Object {
        storageError = '설정을 저장하지 못했어요. 다시 바꿔 주세요.';
        notifyListeners();
      }
    });
    return _pending;
  }

  /// A device at [host]:[port] was connected: remember it. The settings,
  /// telemetry and camera addresses all follow it ([AppSettings.endpoints]);
  /// [secure] for a comma on Wi-Fi (HTTPS/WSS). Refused unless the
  /// local-only policy accepts the origin.
  String? rememberDevice(String host, int port, {bool secure = false}) {
    final origin = Uri(
      scheme: secure ? 'https' : 'http',
      host: host,
      port: port,
    ).toString();
    final error = LocalEndpointPolicy.validateSettings(origin);
    if (error != null) return error;
    update((s) => s.copyWith(lastDeviceEndpoint: origin));
    return null;
  }
}
