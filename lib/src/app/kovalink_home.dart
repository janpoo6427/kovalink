import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/features/settings/vehicle_model_import.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

class KovaLinkHome extends StatefulWidget {
  const KovaLinkHome({
    required this.controller,
    this.vehicleModel,
    this.settings,
    this.library,
    this.modelPicker = pickModelFileWithSystemPicker,
    super.key,
  });

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;
  final SettingsController? settings;
  final VehicleModelLibrary? library;
  final ModelFilePicker modelPicker;

  @override
  State<KovaLinkHome> createState() => _KovaLinkHomeState();
}

class _KovaLinkHomeState extends State<KovaLinkHome> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IndexedStack(
              index: selectedIndex,
              children: [
                _roadView(),
                ConnectScreen(
                  controller: widget.controller,
                  settings: settings,
                ),
                SettingsScreen(
                  controller: widget.controller,
                  vehicleModel: widget.vehicleModel,
                  settings: settings,
                  library: widget.library,
                  modelPicker: widget.modelPicker,
                ),
              ],
            ),
            if (selectedIndex == 0)
              Positioned(
                right: 16,
                bottom: 18,
                child: Row(
                  children: [
                    if (settings != null && widget.library != null) ...[
                      _GlassNavButton(
                        tooltip: '차량 모델 가져오기',
                        icon: Icons.file_download_outlined,
                        onPressed: () => VehicleModelImportFlow.run(
                          context,
                          library: widget.library!,
                          settings: settings,
                          picker: widget.modelPicker,
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    _GlassNavButton(
                      tooltip: '장치 연결',
                      icon: Icons.link_rounded,
                      onPressed: () => setState(() => selectedIndex = 1),
                    ),
                    const SizedBox(width: 10),
                    _GlassNavButton(
                      tooltip: '설정',
                      icon: Icons.settings_outlined,
                      onPressed: () => setState(() => selectedIndex = 2),
                    ),
                  ],
                ),
              )
            else
              Positioned(
                left: 16,
                top: 14,
                child: _GlassNavButton(
                  tooltip: '로드뷰로 돌아가기',
                  icon: Icons.arrow_back_rounded,
                  onPressed: () => setState(() => selectedIndex = 0),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roadView() {
    final settings = widget.settings;
    if (settings == null) {
      return RoadViewScreen(
        controller: widget.controller,
        vehicleModel: widget.vehicleModel,
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
              controller: widget.controller,
              vehicleModel: widget.vehicleModel,
              viewpoint: value.viewpoint,
              theme: value.sceneTheme,
              layers: value.layers,
              speedUnit: value.speedUnit,
              showHud: value.showHud,
              nativeVehicleOverlay: value.nativeVehicleOverlay,
              renderQuality: value.renderQuality,
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

class _GlassNavButton extends StatelessWidget {
  const _GlassNavButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: LiquidGlass(
        radius: 24,
        blur: 18,
        tint: const Color(0x8CFFFFFF),
        padding: EdgeInsets.zero,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, color: const Color(0xFF15191E)),
          iconSize: 21,
        ),
      ),
    );
  }
}
