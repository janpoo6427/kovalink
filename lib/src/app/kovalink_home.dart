import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/app/kova_routes.dart';
import 'package:kovalink/src/app/kovalink_pages.dart';
import 'package:kovalink/src/features/connect/auto_connect_panel.dart';
import 'package:kovalink/src/features/road_view/drive_bottom_bar.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/widgets/glass_nav_button.dart';

/// The drive screen ([KovaRoutes.drive]), at the bottom of the route stack.
/// Its buttons push the connect and settings routes; system back here
/// leaves the app.
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
  );

  @override
  Widget build(BuildContext context) {
    final settings = this.settings;
    final library = this.library;
    final auto = autoConnect;
    void openConnect() => KovaRoutes.open(context, _pages.connectPage());
    // The road view runs under the bottom inset (home indicator, gesture
    // or button nav bar); the bottom bar stays above it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final buttons = <Widget>[
      if (settings != null && library != null)
        GlassNavButton(
          tooltip: '차량 모델 가져오기',
          icon: Icons.file_download_outlined,
          onPressed: () => VehicleModelImportFlow.run(
            context,
            library: library,
            settings: settings,
            picker: modelPicker,
          ),
        ),
      GlassNavButton(
        tooltip: '장치 연결',
        icon: Icons.link_rounded,
        onPressed: openConnect,
      ),
      GlassNavButton(
        tooltip: '설정',
        icon: Icons.settings_outlined,
        onPressed: () =>
            KovaRoutes.open(context, _pages.settingsPage(SettingsTab.app)),
      ),
    ];
    final chip = auto == null
        ? null
        : AutoConnectStatusChip(controller: auto, onTap: openConnect);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) {
            // Beside the buttons when the chip's longest wording fits
            // there, else on a row of its own above them (see DriveBar).
            final bar = DriveBarLayout(
              width: box.maxWidth,
              buttons: buttons.length,
              chip: chip == null
                  ? null
                  : AutoConnectStatusChip.longestSize(context),
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                _roadView(bar.noticeRise),
                if (chip != null && !bar.chipInline)
                  Positioned(
                    right: DriveBar.margin,
                    bottom: bottomInset + bar.chipRowBottom,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: bar.chipMaxWidth),
                      child: chip,
                    ),
                  ),
                Positioned(
                  left: DriveBar.modeClear,
                  right: DriveBar.margin,
                  bottom: bottomInset + DriveBar.bottom,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (chip != null && bar.chipInline) ...[
                        Flexible(child: chip),
                        const SizedBox(width: DriveBar.gap),
                      ],
                      for (final (i, button) in buttons.indexed) ...[
                        if (i > 0) const SizedBox(width: DriveBar.gap),
                        button,
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// [noticeRise]: how much higher than one row the bottom bar reaches;
  /// the road view keeps its notices above it.
  Widget _roadView(double noticeRise) {
    final settings = this.settings;
    if (settings == null) {
      return RoadViewScreen(
        controller: controller,
        vehicleModel: vehicleModel,
        gpuSurfaceBuilder: gpuSurfaceBuilder,
        gpuViewHost: gpuViewHost,
        director: director,
        bottomBarRise: noticeRise,
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
              bottomBarRise: noticeRise,
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
