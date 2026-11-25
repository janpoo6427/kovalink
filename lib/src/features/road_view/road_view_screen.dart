import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:kovalink/src/features/road_view/gpu_road_surface.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/features/road_view/render_quality.dart';
import 'package:kovalink/src/features/road_view/road_scene_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_markers.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/models/display_units.dart';
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
    this.viewpoint = SceneViewpoint.chase,
    this.theme = SceneTheme.clear,
    this.layers = const SceneLayers(),
    this.nativeVehicleOverlay = false,
    this.speedUnit = SpeedUnit.kph,
    this.showHud = true,
    this.renderQuality = RenderQuality.auto,
    this.gpuSurfaceBuilder,
    this.director,
    super.key,
  });
  final GatewayController controller;

  /// Loaded model pack. Null keeps the bundled default pack.
  final ValueListenable<VehicleModelLoadResult>? vehicleModel;
  final SceneViewpoint viewpoint;
  final SceneTheme theme;
  final SceneLayers layers;

  /// Layer the model pack's GLB (thermion) over the chase view on
  /// Android/iOS. Off by default: the built-in renderer already draws the
  /// ego in the same camera as the road.
  final bool nativeVehicleOverlay;
  final SpeedUnit speedUnit;

  /// 설정 → 표시 항목 → HUD 수치.
  final bool showHud;

  /// 설정 → 화질: 자동(기본) / 고품질(GPU) / 절약(소프트웨어).
  final RenderQuality renderQuality;

  /// Replaces the live GPU view (tests and worker captures draw frames
  /// from the same renderer headlessly). Its presence also marks the GPU
  /// path as available.
  final GpuSurfaceBuilder? gpuSurfaceBuilder;

  /// Camera operator shared with a capture tool; null = own instance.
  final SceneDirector? director;

  @override
  State<RoadViewScreen> createState() => _RoadViewScreenState();
}

class _RoadViewScreenState extends State<RoadViewScreen> {
  RoadViewMode mode = RoadViewMode.scene;
  late final SceneDirector _director = widget.director ?? SceneDirector();
  bool _gpuFailed = false;

  bool get _useGpu => RenderQualityPolicy.useGpu(
    widget.renderQuality,
    gpuAvailable:
        !_gpuFailed &&
        (widget.gpuSurfaceBuilder != null || GpuRoadSurface.supported),
  );

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
            final notice = HudLayout(
              constraints.biggest,
              compact: compact,
              showNumbers: widget.showHud,
              bottomInset: MediaQuery.paddingOf(context).bottom,
            ).noticeArea;
            final frame = _director.update(
              scene,
              constraints.biggest,
              viewpoint: widget.viewpoint,
              vehicle: _vehicleModel.profile,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                _buildRoadSurface(scene, frame, notice),
                DriveHud(
                  scene: scene,
                  compact: compact,
                  unit: widget.speedUnit,
                  showNumbers: widget.showHud,
                ),
                Positioned(
                  left: 18,
                  bottom: 22 + MediaQuery.paddingOf(context).bottom,
                  child: _ModeButton(
                    mode: mode,
                    onPressed: () => setState(() {
                      mode =
                          RoadViewMode.values[(mode.index + 1) %
                              RoadViewMode.values.length];
                    }),
                  ),
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

  Widget _buildRoadSurface(
    RoadScene scene,
    DirectorFrame frame,
    NoticeArea notice,
  ) {
    if (mode == RoadViewMode.scene) {
      final vehicleModel = _vehicleModel;
      final glbAssetPath = vehicleModel.glbAssetPath;
      final look = SceneLook.resolve(widget.theme, scene.roadType);
      final rain = look.rain
          ? IgnorePointer(
              child: CustomPaint(
                painter: RainOverlayPainter(
                  timeSeconds: scene.monotonicTimeNanos / 1e9,
                ),
              ),
            )
          : null;
      if (_useGpu) {
        final request = GpuSurfaceRequest(
          scene: scene,
          director: frame,
          theme: widget.theme,
          layers: widget.layers,
          vehicle: vehicleModel.profile,
          viewpoint: widget.viewpoint,
          egoGlbPath: vehicleModel.manifest.id == 'kovalink-basic'
              ? null
              : glbAssetPath,
          egoBodyNode: vehicleModel.manifest.nodes.body,
          egoExcludeNodes: vehicleModel.manifest.excludeNodes.toSet(),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.gpuSurfaceBuilder?.call(context, request) ??
                GpuRoadSurface(
                  request: request,
                  onFallback: () {
                    if (widget.renderQuality == RenderQuality.auto) {
                      setState(() => _gpuFailed = true);
                    }
                  },
                ),
            if (widget.layers.objects)
              IgnorePointer(
                child: CustomPaint(
                  painter: SceneMarkersPainter(
                    scene: scene,
                    frame: frame,
                    egoLength: vehicleModel.profile.dimensions.length,
                    egoWidth: vehicleModel.profile.dimensions.width,
                    fontFamily: DefaultTextStyle.of(context).style.fontFamily,
                  ),
                ),
              ),
            ?rain,
          ],
        );
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: RoadWorldPainter(
                scene: scene,
                vehicle: vehicleModel.profile,
                viewpoint: widget.viewpoint,
                theme: widget.theme,
                layers: widget.layers,
                labelFontFamily: DefaultTextStyle.of(context).style.fontFamily,
                egoMesh: vehicleModel.mesh,
                director: frame,
              ),
            ),
          ),
          ?rain,
          if (widget.nativeVehicleOverlay &&
              widget.viewpoint == SceneViewpoint.chase &&
              _supportsNativeVehicle &&
              glbAssetPath != null)
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
        notice: notice,
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
          _NoticeSlot(
            notice: notice,
            maxWidth: 360,
            child: const _CalibrationWarning(),
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

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.mode, required this.onPressed});
  final RoadViewMode mode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: switch (mode) {
        RoadViewMode.scene => '카메라 화면으로 바꾸기',
        RoadViewMode.camera => '카메라에 도로 겹쳐 보기',
        RoadViewMode.overlay => '3D 화면으로 바꾸기',
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
              '카메라 보정이 끝나면 도로 표시가 겹쳐 나와요.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({
    required this.status,
    required this.notice,
    this.errorMessage,
  });
  final RoadStreamStatus status;
  final NoticeArea notice;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1B2939), Color(0xFF070B11)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _NoticeSlot(
            notice: notice,
            maxWidth: 380,
            child: _CameraNotice(
              title: status == RoadStreamStatus.connecting
                  ? '카메라 연결 중'
                  : '카메라가 연결되지 않았어요',
              detail: errorMessage ?? '연결 화면에서 카메라를 켜 주세요.',
            ),
          ),
        ],
      ),
    );
  }
}

/// Puts a notice in the room the HUD leaves free (see
/// [HudLayout.noticeArea]): never under the HUD parts, the bottom buttons
/// or a navigation app's overlay on the right. Scales down instead of
/// overflowing when the room is tight.
class _NoticeSlot extends StatelessWidget {
  const _NoticeSlot({
    required this.notice,
    required this.maxWidth,
    required this.child,
  });

  final NoticeArea notice;
  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned.fromRect(
    rect: notice.area,
    child: LayoutBuilder(
      builder: (context, box) => Align(
        alignment: notice.alignment,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: notice.alignment,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(120, math.min(maxWidth, box.maxWidth)),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// Lets Korean text wrap only between words: Flutter otherwise breaks
/// lines between any two syllables ("연결되 / 지"). Word joiners (U+2060,
/// invisible) go between the letters of each word.
String _keepWords(String text) =>
    text.split(' ').map((word) => word.characters.join('\u2060')).join(' ');

/// Camera state card: icon beside the text when there is room for one
/// row, icon above it on narrow spots.
class _CameraNotice extends StatelessWidget {
  const _CameraNotice({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 300;
        final titleText = Text(
          _keepWords(title),
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700),
        );
        final detailText = Text(
          _keepWords(detail),
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: const TextStyle(color: Color(0xFFB5C0CB), fontSize: 12),
        );
        const icon = Icon(Icons.videocam_off_outlined, size: 32);
        return LiquidGlass(
          key: const ValueKey('camera-notice'),
          padding: wide
              ? const EdgeInsets.fromLTRB(16, 12, 20, 12)
              : const EdgeInsets.all(12),
          child: wide
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    icon,
                    const SizedBox(width: 14),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleText,
                          const SizedBox(height: 4),
                          detailText,
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    icon,
                    const SizedBox(height: 8),
                    titleText,
                    const SizedBox(height: 4),
                    detailText,
                  ],
                ),
        );
      },
    );
  }
}
