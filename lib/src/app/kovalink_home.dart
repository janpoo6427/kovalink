import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_pages.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/comma_link.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/widgets/glass_nav_button.dart';

/// The drive screen ([KovaRoutes.drive]), at the bottom of the route stack.
/// Its one button pushes the settings route (장치 연결 and 차량 모델
/// 가져오기 live in settings); the 자동 연결 chip pushes the connect route.
/// System back here leaves the app.
class KovaLinkHome extends StatelessWidget {
  const KovaLinkHome({
    required this.controller,
    this.vehicleModel,
    this.settings,
    this.library,
    this.modelPicker = pickModelFileWithSystemPicker,
    this.gpuSurfaceBuilder,
    this.gpuViewHost,
    this.director,
    this.kovaParams,
    this.autoConnect,
    this.link,
    super.key,
  });

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;
  final SettingsController? settings;
  final VehicleModelLibrary? library;
  final ModelFilePicker modelPicker;

  /// kovapilot settings connection shown in the settings tab.
  final KovaParamsController? kovaParams;

  /// 자동 연결; shown as a small chip on the road view.
  final AutoConnectController? autoConnect;

  /// Registered comma and its session (connect screen).
  final CommaLink? link;

  /// Capture/test hooks forwarded to [RoadViewScreen].
  final GpuSurfaceBuilder? gpuSurfaceBuilder;
  final GpuViewHost? gpuViewHost;
  final SceneDirector? director;

  KovaLinkPages get _pages => KovaLinkPages(
    controller: controller,
    vehicleModel: vehicleModel,
    settings: settings,
    library: library,
    modelPicker: modelPicker,
    kovaParams: kovaParams,
    autoConnect: autoConnect,
    link: link,
  );

  @override
  Widget build(BuildContext context) {
    void openConnect() => KovaRoutes.open(context, _pages.connectPage());
    // The road view runs under the bottom inset (home indicator, gesture
    // or button nav bar); the buttons stay above it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _roadView(),
            Positioned(
              right: 16,
              bottom: 18 + bottomInset,
              child: Row(
                children: [
                  if (autoConnect case final auto?) ...[
                    AutoConnectStatusChip(controller: auto, onTap: openConnect),
                    const SizedBox(width: 10),
                  ],
                  GlassNavButton(
                    tooltip: '설정',
                    icon: Icons.settings_outlined,
                    onPressed: () => KovaRoutes.open(
                      context,
                      _pages.settingsPage(SettingsTab.app),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roadView() {
    final settings = this.settings;
    if (settings == null) {
      return RoadViewScreen(
        controller: controller,
        vehicleModel: vehicleModel,
        gpuSurfaceBuilder: gpuSurfaceBuilder,
        gpuViewHost: gpuViewHost,
        director: director,
      );
    }
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final value = settings.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            RoadViewScreen(
              controller: controller,
              vehicleModel: vehicleModel,
              viewpoint: value.viewpoint,
              theme: value.sceneTheme,
              layers: value.layers,
              speedUnit: value.speedUnit,
              showHud: value.showHud,
              nativeVehicleOverlay: value.nativeVehicleOverlay,
              renderQuality: value.renderQuality,
              gpuSurfaceBuilder: gpuSurfaceBuilder,
              gpuViewHost: gpuViewHost,
              director: director,
            ),
            if (value.brightness < 1)
              IgnorePointer(
                child: ColoredBox(
                  key: const ValueKey('road-dimmer'),
                  color: Colors.black.withValues(
                    alpha: (1 - value.brightness).clamp(0.0, 0.6),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
