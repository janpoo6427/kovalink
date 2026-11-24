import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:kovalink/src/features/road_view/scene3d/road_world_painter.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_palette.dart';
import 'package:kovalink/src/gpu_scene/gpu_road_renderer.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:thermion_flutter/thermion_flutter.dart';

/// Everything a GPU surface needs to draw one frame.
class GpuSurfaceRequest {
  const GpuSurfaceRequest({
    required this.scene,
    required this.director,
    required this.theme,
    required this.layers,
    required this.vehicle,
    required this.viewpoint,
    this.egoGlbPath,
  });

  final RoadScene scene;
  final DirectorFrame director;
  final SceneTheme theme;
  final SceneLayers layers;
  final EgoVehicleProfile vehicle;
  final SceneViewpoint viewpoint;

  /// GLB of an imported model pack (asset path or file path); null = the
  /// built-in KovaLink SUV with GPU materials.
  final String? egoGlbPath;
}

/// Builds the GPU surface for a request. Tests and worker captures inject
/// a builder that shows a frame rendered headlessly by the same
/// [GpuRoadRenderer]; the app uses [GpuRoadSurface].
typedef GpuSurfaceBuilder =
    Widget Function(BuildContext context, GpuSurfaceRequest request);

/// Live Filament view (thermion texture) driven by [GpuRoadRenderer].
/// Frames are coalesced: while one update is in flight only the newest
/// request is kept, so a slow phone drops frames instead of lagging.
class GpuRoadSurface extends StatefulWidget {
  const GpuRoadSurface({required this.request, this.onFallback, super.key});

  final GpuSurfaceRequest request;

  /// Called once if the GPU view cannot start or stays too slow (average
  /// update above [slowFrameMs] over [slowWindow] frames); the screen then
  /// switches to the software renderer in automatic mode.
  final VoidCallback? onFallback;

  static const slowFrameMs = 70;
  static const slowWindow = 90;

  /// Platforms where the thermion plugin renders into a Flutter texture
  /// (the real OS, so widget tests on a desktop host stay on software).
  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  State<GpuRoadSurface> createState() => _GpuRoadSurfaceState();
}

class _GpuRoadSurfaceState extends State<GpuRoadSurface> {
  GpuRoadRenderer? _renderer;
  bool _busy = false;
  GpuSurfaceRequest? _pending;
  Size _size = Size.zero;
  String? _glbPath;
  Uint8List? _glb;

  @override
  void didUpdateWidget(covariant GpuRoadSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule(widget.request);
  }

  void _schedule(GpuSurfaceRequest request) {
    _pending = request;
    if (_busy || _renderer == null) return;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    _busy = true;
    try {
      while (_pending != null && mounted) {
        final request = _pending!;
        _pending = null;
        if (request.egoGlbPath != _glbPath) {
          _glbPath = request.egoGlbPath;
          _glb = await _readGlb(request.egoGlbPath);
        }
        if (!mounted) return;
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final sw = Stopwatch()..start();
        await _renderer!.update(
          GpuFrameInput(
            scene: request.scene,
            director: request.director,
            width: (_size.width * dpr).round().clamp(16, 4096),
            height: (_size.height * dpr).round().clamp(16, 4096),
            theme: request.theme,
            layers: request.layers,
            vehicle: request.vehicle,
            viewpoint: request.viewpoint,
            egoPackGlb: _glb,
            egoPackKey: _glbPath,
          ),
        );
        _frames++;
        _totalMs += sw.elapsedMilliseconds;
        if (_frames == GpuRoadSurface.slowWindow) {
          if (_totalMs / _frames > GpuRoadSurface.slowFrameMs) _fallback();
          _frames = 0;
          _totalMs = 0;
        }
      }
    } catch (_) {
      _fallback();
    } finally {
      _busy = false;
    }
  }

  int _frames = 0;
  int _totalMs = 0;
  bool _fellBack = false;

  void _fallback() {
    if (_fellBack) return;
    _fellBack = true;
    widget.onFallback?.call();
  }

  static Future<Uint8List?> _readGlb(String? path) async {
    if (path == null) return null;
    if (path.startsWith('asset://')) {
      final data = await rootBundle.load(path.substring(8));
      return data.buffer.asUint8List();
    }
    final file = File(
      path.startsWith('file://') ? Uri.parse(path).toFilePath() : path,
    );
    return file.existsSync() ? file.readAsBytes() : null;
  }

  @override
  void dispose() {
    unawaited(_renderer?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return ThermionWidget.create(
          viewerFactory: () async {
            try {
              final viewer = await ThermionFlutterPlugin.createViewer();
              await viewer.setRendering(true);
              _renderer = GpuRoadRenderer(viewer);
              _schedule(widget.request);
              return viewer;
            } catch (_) {
              _fallback();
              rethrow;
            }
          },
        );
      },
    );
  }
}
