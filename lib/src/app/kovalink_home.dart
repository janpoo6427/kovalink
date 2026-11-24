import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/connect/connect_screen.dart';
import 'package:kovalink/src/features/road_view/road_view_screen.dart';
import 'package:kovalink/src/features/settings/settings_screen.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

class KovaLinkHome extends StatefulWidget {
  const KovaLinkHome({required this.controller, this.vehicleModel, super.key});

  final GatewayController controller;
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;

  @override
  State<KovaLinkHome> createState() => _KovaLinkHomeState();
}

class _KovaLinkHomeState extends State<KovaLinkHome> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            IndexedStack(
              index: selectedIndex,
              children: [
                RoadViewScreen(
                  controller: widget.controller,
                  vehicleModel: widget.vehicleModel,
                ),
                ConnectScreen(controller: widget.controller),
                SettingsScreen(
                  controller: widget.controller,
                  vehicleModel: widget.vehicleModel,
                ),
              ],
            ),
            if (selectedIndex == 0)
              Positioned(
                right: 16,
                bottom: 18,
                child: Row(
                  children: [
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
        tint: const Color(0x3814202E),
        padding: EdgeInsets.zero,
        child: IconButton(onPressed: onPressed, icon: Icon(icon), iconSize: 21),
      ),
    );
  }
}
