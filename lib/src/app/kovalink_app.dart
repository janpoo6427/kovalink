import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kovalink_home.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:path_provider/path_provider.dart';

class KovaLinkApp extends StatefulWidget {
  const KovaLinkApp({
    super.key,
    this.vehicleBundle,
    this.settingsStore,
    this.storageRoot,
    this.modelPicker = pickModelFileWithSystemPicker,
  });

  /// Asset bundle for the vehicle model pack; null uses rootBundle.
  final AssetBundle? vehicleBundle;

  /// Settings persistence; null = JSON file in the app support directory.
  final SettingsStore? settingsStore;

  /// App-private storage root for settings and imported model packs.
  final Future<Directory> Function()? storageRoot;
  final ModelFilePicker modelPicker;

  @override
  State<KovaLinkApp> createState() => _KovaLinkAppState();
}

class _KovaLinkAppState extends State<KovaLinkApp> {
  late final GatewayController controller;
  late final SettingsController settings;
  late final VehicleModelLibrary library;
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
    _loadVehicleModel();
    settings.load();
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
    setState(() {});
  }

  Future<void> _loadVehicleModel() async {
    final id = settings.value.vehicleModelId;
    _loadedModelId = id;
    _modelLoaded = true;
    final result = await library.load(id);
    if (!mounted || _loadedModelId != id) return;
    vehicleModel.value = result;
  }

  @override
  void dispose() {
    settings.removeListener(_applySettings);
    controller.dispose();
    settings.dispose();
    vehicleModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF58F2C2);
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
