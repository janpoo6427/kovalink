import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:kovalink/src/features/road_view/road_scene_painter.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/services/web_rtc_road_stream.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';
import 'package:thermion_flutter/thermion_flutter.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

enum RoadViewMode { scene, camera, overlay }

class RoadViewScreen extends StatefulWidget {
  const RoadViewScreen({
    required this.controller,
    this.vehicleModel,
    super.key,
  });
  final GatewayController controller;

  /// Loaded model pack. Null keeps the bundled default pack.
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;

  @override
  State<RoadViewScreen> createState() => _RoadViewScreenState();
}

class _RoadViewScreenState extends State<RoadViewScreen> {
  RoadViewMode mode = RoadViewMode.scene;

  static bool get _supportsNativeVehicle =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.controller.roadStream,
        ?widget.vehicleModel,
      ]),
      builder: (context, _) {
        final scene = widget.controller.scene;
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 680;
            return Stack(
              fit: StackFit.expand,
              children: [
                _buildRoadSurface(scene),
                Positioned(left: 18, top: 16, child: _DriveState(scene: scene)),
                Positioned(
                  top: 18,
                  left: compact ? null : constraints.maxWidth * 0.36,
                  right: compact ? 90 : constraints.maxWidth * 0.36,
                  child: _TurnSignalPanel(scene: scene),
                ),
                Positioned(
                  right: 18,
                  top: 16,
                  child: _SpeedLimit(value: scene.speedLimitKph),
                ),
                if (scene.tbt != null)
                  Positioned(
                    top: compact ? 142 : 132,
                    right: 18,
                    width: compact ? 272 : 320,
                    child: _TbtCard(instruction: scene.tbt!, compact: compact),
                  ),
                Positioned(
                  left: 18,
                  bottom: 22,
                  child: _ModeButton(
                    mode: mode,
                    onPressed: () => setState(() {
                      mode =
                          RoadViewMode.values[(mode.index + 1) %
                              RoadViewMode.values.length];
                    }),
                  ),
                ),
                if (scene.tbt != null && !compact)
                  Positioned(
                    bottom: 24,
                    left: constraints.maxWidth * 0.38,
                    right: constraints.maxWidth * 0.38,
                    child: _NextTurnPill(instruction: scene.tbt!),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  VehicleModelLoadResult get _vehicleModel =>
      widget.vehicleModel?.value ?? VehicleModelLoadResult.bundledDefault;

  Widget _buildRoadSurface(RoadScene scene) {
    if (mode == RoadViewMode.scene) {
      final vehicleModel = _vehicleModel;
      final glbAssetPath = vehicleModel.glbAssetPath;
      return Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: RoadScenePainter(
                scene,
                // Deterministic underlay: the native GLB covers this when
                // available, and unsupported GPUs never leave the road empty.
                drawEgoVehicle: true,
                vehicle: vehicleModel.profile,
              ),
            ),
          ),
          if (_supportsNativeVehicle && glbAssetPath != null)
            Positioned(
              left: 24,
              right: 24,
              bottom: 18,
              height: 340,
              child: IgnorePointer(
                child: _NativeVehicleModel(
                  key: ValueKey(glbAssetPath),
                  assetPath: glbAssetPath,
                ),
              ),
            ),
        ],
      );
    }

    final stream = widget.controller.roadStream;
    if (!stream.hasVideo) {
      return _CameraPlaceholder(
        status: stream.status,
        errorMessage: stream.errorMessage,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        RTCVideoView(
          stream.renderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          filterQuality: FilterQuality.medium,
        ),
        if (mode == RoadViewMode.overlay && scene.cameraProjection != null)
          IgnorePointer(
            child: CustomPaint(
              painter: RoadScenePainter(
                scene,
                drawEnvironment: false,
                cameraAligned: true,
              ),
            ),
          ),
        if (mode == RoadViewMode.overlay && scene.cameraProjection == null)
          const Positioned(
            left: 18,
            right: 18,
            top: 116,
            child: _CalibrationWarning(),
          ),
      ],
    );
  }
}

class _NativeVehicleModel extends StatefulWidget {
  const _NativeVehicleModel({required this.assetPath, super.key});

  final String assetPath;

  @override
  State<_NativeVehicleModel> createState() => _NativeVehicleModelState();
}

class _NativeVehicleModelState extends State<_NativeVehicleModel> {
  late final ViewerWidget _viewer = ViewerWidget(
    assetPath: widget.assetPath,
    initial: const SizedBox.expand(),
    initialCameraPosition: vector.Vector3(1.65, 1.05, 2.55),
    manipulatorType: ManipulatorType.NONE,
    background: Colors.transparent,
    postProcessing: true,
    transformToUnitCube: true,
    directLight: DirectLight.sun(
      direction: vector.Vector3(-0.7, -1.4, -0.8),
      intensity: 110000,
    ),
  );

  @override
  Widget build(BuildContext context) => _viewer;
}

class _DriveState extends StatelessWidget {
  const _DriveState({required this.scene});
  final RoadScene scene;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '현재 속도 ${scene.speedKph.round()} 킬로미터, 기어 ${scene.gear.name}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${scene.speedKph.round()}',
                style: const TextStyle(
                  fontSize: 62,
                  height: 0.88,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -4,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, bottom: 6),
                child: Text(
                  'km/h',
                  style: TextStyle(
                    color: Color(0xFFB5C0CB),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: VehicleGear.values
                .take(4)
                .map((gear) {
                  final selected = gear == scene.gear;
                  return Padding(
                    padding: const EdgeInsets.only(right: 11),
                    child: Text(
                      _gearLabel(gear),
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.28),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  );
                })
                .toList(growable: false),
          ),
          const SizedBox(height: 12),
          LiquidGlass(
            radius: 15,
            blur: 14,
            tint: const Color(0x26111A24),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  scene.engaged
                      ? Icons.assistant_navigation
                      : Icons.sports_motorsports_outlined,
                  size: 15,
                  color: scene.engaged
                      ? const Color(0xFF68E7C0)
                      : const Color(0xFFB5C0CB),
                ),
                const SizedBox(width: 7),
                Text(
                  scene.engaged
                      ? '주행 보조 ${scene.setSpeedKph.round()}'
                      : '조향 보조 대기',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _gearLabel(VehicleGear gear) => switch (gear) {
    VehicleGear.park => 'P',
    VehicleGear.reverse => 'R',
    VehicleGear.neutral => 'N',
    VehicleGear.drive => 'D',
    VehicleGear.unknown => '–',
  };
}

class _TurnSignalPanel extends StatelessWidget {
  const _TurnSignalPanel({required this.scene});
  final RoadScene scene;

  @override
  Widget build(BuildContext context) {
    final blinkOn = (scene.monotonicTimeNanos ~/ 500000000).isEven;
    Color color(bool active) => active && blinkOn
        ? const Color(0xFF67E5A7)
        : Colors.white.withValues(alpha: 0.16);
    return LiquidGlass(
      radius: 18,
      blur: 16,
      tint: const Color(0x24172634),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Icon(Icons.arrow_back_rounded, color: color(scene.leftBlinker)),
          Icon(Icons.arrow_forward_rounded, color: color(scene.rightBlinker)),
        ],
      ),
    );
  }
}

class _SpeedLimit extends StatelessWidget {
  const _SpeedLimit({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 61,
          height: 61,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFEE3843), width: 6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x55000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Text(
            value?.round().toString() ?? '–',
            style: const TextStyle(
              color: Color(0xFF17191D),
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          '제한속도',
          style: TextStyle(
            color: Color(0xFFB5C0CB),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _TbtCard extends StatelessWidget {
  const _TbtCard({required this.instruction, this.compact = false});
  final TbtInstruction instruction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      tint: const Color(0x3C172534),
      padding: EdgeInsets.all(compact ? 13 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (instruction.roadName != null)
            Text(
              instruction.roadName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFB5C0CB), fontSize: 12),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(_maneuverIcon(instruction.maneuver), size: 31),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _maneuverLabel(instruction.maneuver),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                _distance(instruction.distanceMeters),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          if (!compact && instruction.remainingDistanceMeters != null) ...[
            const SizedBox(height: 12),
            Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
            const SizedBox(height: 10),
            Text(
              '${_distance(instruction.remainingDistanceMeters!)} 남음'
              '${instruction.remainingSeconds == null ? '' : ' · ${_duration(instruction.remainingSeconds!)}'}',
              style: const TextStyle(
                color: Color(0xFFB5C0CB),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NextTurnPill extends StatelessWidget {
  const _NextTurnPill({required this.instruction});
  final TbtInstruction instruction;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      radius: 24,
      tint: const Color(0x421A2A3C),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _maneuverIcon(instruction.maneuver),
            color: const Color(0xFF72A7FF),
          ),
          const SizedBox(width: 9),
          Text(
            _distance(instruction.distanceMeters),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.onPressed});
  final RoadViewMode mode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: switch (mode) {
        RoadViewMode.scene => '3D 로드뷰 · 탭하여 카메라로 전환',
        RoadViewMode.camera => '카메라 · 탭하여 오버레이로 전환',
        RoadViewMode.overlay => '카메라 오버레이 · 탭하여 3D로 전환',
      },
      child: LiquidGlass(
        radius: 22,
        blur: 16,
        tint: const Color(0x32131F2C),
        padding: EdgeInsets.zero,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(switch (mode) {
            RoadViewMode.scene => Icons.view_in_ar_outlined,
            RoadViewMode.camera => Icons.videocam_outlined,
            RoadViewMode.overlay => Icons.layers_outlined,
          }),
        ),
      ),
    );
  }
}

class _CalibrationWarning extends StatelessWidget {
  const _CalibrationWarning();

  @override
  Widget build(BuildContext context) {
    return const LiquidGlass(
      tint: Color(0x66302716),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFFFC857)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '카메라 calibration을 받기 전에는 AR overlay를 표시하지 않습니다.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({required this.status, this.errorMessage});
  final RoadStreamStatus status;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B2939), Color(0xFF070B11)],
        ),
      ),
      child: Center(
        child: LiquidGlass(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, size: 44),
              const SizedBox(height: 12),
              Text(
                status == RoadStreamStatus.connecting
                    ? 'WebRTC 카메라 연결 중'
                    : 'WebRTC 카메라 gateway가 필요합니다',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                errorMessage ?? '연결 화면에서 카메라 스트림을 시작하세요',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFB5C0CB), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _maneuverIcon(TbtManeuver maneuver) => switch (maneuver) {
  TbtManeuver.turnLeft => Icons.turn_left_rounded,
  TbtManeuver.turnRight => Icons.turn_right_rounded,
  TbtManeuver.slightLeft => Icons.turn_slight_left_rounded,
  TbtManeuver.slightRight => Icons.turn_slight_right_rounded,
  TbtManeuver.uTurn => Icons.u_turn_left_rounded,
  TbtManeuver.arrive => Icons.flag_rounded,
  _ => Icons.straight_rounded,
};

String _maneuverLabel(TbtManeuver maneuver) => switch (maneuver) {
  TbtManeuver.turnLeft => '좌회전',
  TbtManeuver.turnRight => '우회전',
  TbtManeuver.slightLeft => '왼쪽 방향',
  TbtManeuver.slightRight => '오른쪽 방향',
  TbtManeuver.uTurn => '유턴',
  TbtManeuver.arrive => '목적지 도착',
  _ => '직진',
};

String _distance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} km'
    : '${meters.round()} m';

String _duration(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours > 0 ? '$hours시간 $minutes분' : '$minutes분';
}
