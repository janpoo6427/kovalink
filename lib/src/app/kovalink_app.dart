import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/network/device_discovery.dart';
import 'package:kovalink/src/services/app_auto_connect_target.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_mesh/vehicle_mesh_loader.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:path_provider/path_provider.dart';

class KovaLinkApp extends StatefulWidget {
  const KovaLinkApp({
    super.key,
    this.vehicleBundle,
    this.settingsStore,
    this.storageRoot,
    this.modelPicker = pickModelFileWithSystemPicker,
    this.autoConnectBuilder,
  });

  /// Asset bundle for the vehicle model pack; null uses rootBundle.
  final AssetBundle? vehicleBundle;

  /// Settings persistence; null = JSON file in the app support directory.
  final SettingsStore? settingsStore;

  /// App-private storage root for settings and imported model packs.
  final Future<Directory> Function()? storageRoot;
  final ModelFilePicker modelPicker;

  /// Builds the 자동 연결 controller. Null uses the real network search,
  /// except under `flutter test` (FLUTTER_TEST), where no real interface is
  /// listed or scanned unless a test passes its own builder.
  final AutoConnectController Function(
    AutoConnectTarget target,
    SettingsController settings,
  )?
  autoConnectBuilder;

  static bool get _underFlutterTest =>
      Platform.environment.containsKey('FLUTTER_TEST');

  static const accentColor = Color(0xFF58F2C2);

  /// The app theme (also used by layout tests and review captures).
  static ThemeData theme(Brightness brightness) =>
      _KovaLinkAppState._theme(brightness, accentColor);

  @override
  State<KovaLinkApp> createState() => _KovaLinkAppState();
}

class _KovaLinkAppState extends State<KovaLinkApp> with WidgetsBindingObserver {
  late final GatewayController controller;
  late final SettingsController settings;
  late final VehicleModelLibrary library;
  AutoConnectController? autoConnect;
  TelemetryWatch? _telemetryWatch;
  // kovapilot settings over HTTP. Opened by 자동 연결 once the comma answers,
  // or when the user taps 연결 in the kovapilot tab.
  final kovaParams = KovaParamsController();
  final vehicleModel = ValueNotifier<VehicleModelLoadResult>(
    VehicleModelLoadResult.bundledDefault,
  );
  String? _loadedModelId;
  bool _modelLoaded = false;

  @override
  void initState() {
    super.initState();
    final storageRoot = widget.storageRoot ?? getApplicationSupportDirectory;
    library = VehicleModelLibrary(
      storageRoot: storageRoot,
      bundle: widget.vehicleBundle,
    );
    settings = SettingsController(
      store: widget.settingsStore ?? FileSettingsStore(storageRoot),
    )..addListener(_applySettings);
    controller = GatewayController()
      ..startDemo(route: settings.value.demoRoute);
    final target = AppAutoConnectTarget(
      controller: controller,
      settings: settings,
      kovaParams: kovaParams,
    );
    autoConnect =
        widget.autoConnectBuilder?.call(target, settings) ??
        (KovaLinkApp._underFlutterTest
            ? null
            : AutoConnectController(
                target: target,
                lastEndpoint: () => settings.value.lastDeviceEndpoint,
                knownEndpoints: () => [settings.value.settingsEndpoint],
                portsProvider: () => _ports(settings),
              ));
    if (autoConnect case final auto?) {
      _telemetryWatch = TelemetryWatch(
        controller: controller,
        autoConnect: auto,
      );
    }
    WidgetsBinding.instance.addObserver(this);
    _loadVehicleModel();
    settings.load();
  }

  /// The gateway default port, plus the saved settings port if different.
  static List<int> _ports(SettingsController settings) {
    final ports = {kovaGatewayDefaultPort};
    final saved = settings.value.settingsEndpoint;
    final uri = Uri.tryParse(saved);
    if (uri != null && uri.hasPort) ports.add(uri.port);
    return ports.toList();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        autoConnect?.setForeground(true);
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        autoConnect?.setForeground(false);
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Keeps the demo, model and theme in sync with saved settings. A live
  /// or connecting gateway session is never interrupted by the demo switch.
  void _applySettings() {
    final value = settings.value;
    final idle =
        controller.mode != GatewayMode.live &&
        controller.mode != GatewayMode.connecting;
    if (idle) {
      if (value.demoMode &&
          (controller.mode != GatewayMode.demo ||
              controller.demoRoute != value.demoRoute)) {
        controller.startDemo(route: value.demoRoute);
      } else if (!value.demoMode && controller.mode == GatewayMode.demo) {
        controller.stopDemo();
      }
    }
    if (!_modelLoaded || value.vehicleModelId != _loadedModelId) {
      _loadVehicleModel();
    }
    if (settings.loaded) autoConnect?.setEnabled(value.autoConnect);
    setState(() {});
  }

  Future<void> _loadVehicleModel() async {
    final id = settings.value.vehicleModelId;
    _loadedModelId = id;
    _modelLoaded = true;
    final result = await library.load(id);
    if (!mounted || _loadedModelId != id) return;
    vehicleModel.value = result;
    // The road renderer draws the pack's own mesh once it is read.
    final load = await VehicleMeshLoader.load(
      result.glbAssetPath,
      result.manifest,
      bundle: widget.vehicleBundle,
    );
    if (!mounted || _loadedModelId != id) return;
    vehicleModel.value = result.withMesh(load.mesh, load.warnings);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _telemetryWatch?.dispose();
    autoConnect?.dispose();
    settings.removeListener(_applySettings);
    controller.dispose();
    kovaParams.dispose();
    settings.dispose();
    vehicleModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = KovaLinkApp.accentColor;
    return MaterialApp(
      title: 'KovaLink',
      debugShowCheckedModeBanner: false,
      themeMode: switch (settings.value.appTheme) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      },
      theme: _theme(Brightness.light, accent),
      darkTheme: _theme(Brightness.dark, accent),
      home: KovaLinkHome(
        controller: controller,
        vehicleModel: vehicleModel,
        settings: settings,
        library: library,
        modelPicker: widget.modelPicker,
        kovaParams: kovaParams,
        autoConnect: autoConnect,
      ),
    );
  }

  static ThemeData _theme(Brightness brightness, Color accent) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF111820) : const Color(0xFFF4F6F8);
    return ThemeData(
      brightness: brightness,
      colorScheme: dark
          ? ColorScheme.dark(
              primary: accent,
              secondary: const Color(0xFF72A7FF),
              surface: surface,
              error: const Color(0xFFFF6B72),
            )
          : ColorScheme.light(
              primary: const Color(0xFF0E8F6E),
              secondary: const Color(0xFF2F6BEA),
              surface: surface,
              error: const Color(0xFFD93A42),
            ),
      scaffoldBackgroundColor: dark
          ? const Color(0xFF070B10)
          : const Color(0xFFE9EDF1),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF0C1219) : Colors.white,
        indicatorColor: const Color(0x3358F2C2),
        height: 72,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF0A1016) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: dark ? const Color(0xFF27323D) : const Color(0xFFCBD3DB),
          ),
        ),
      ),
      useMaterial3: true,
    );
  }
}
