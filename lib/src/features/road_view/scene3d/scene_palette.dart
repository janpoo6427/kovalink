import 'dart:math' as math;
import 'dart:ui';

import 'package:kovalink/src/features/road_view/scene3d/scene_theme.dart';
import 'package:kovalink/src/models/road_scene.dart';

export 'package:kovalink/src/features/road_view/scene3d/scene_theme.dart';

/// Colors and fog for one (theme, road type) pair. Pure display values.
class ScenePalette {
  const ScenePalette({
    required this.skyTop,
    required this.skyHorizon,
    required this.fog,
    required this.fogDensity,
    required this.groundNear,
    required this.shoulder,
    required this.asphaltNear,
    required this.asphaltSeam,
    required this.laneWhite,
    required this.laneYellow,
    required this.laneBlue,
    required this.roadEdge,
    required this.foliage,
    required this.trunk,
    required this.building,
    required this.otherVehicle,
    required this.leadVehicle,
    required this.lightDirection,
    required this.shadowAlpha,
    required this.scenery,
  });

  final Color skyTop;
  final Color skyHorizon;
  final Color fog;

  /// Exponential fog density per meter of depth.
  final double fogDensity;
  final Color groundNear;
  final Color shoulder;
  final Color asphaltNear;
  final Color asphaltSeam;
  final Color laneWhite;
  final Color laneYellow;
  final Color laneBlue;
  final Color roadEdge;
  final List<Color> foliage;
  final Color trunk;
  final Color building;
  final Color otherVehicle;
  final Color leadVehicle;

  /// Unit vector toward the light (x forward, y left, z up).
  final (double, double, double) lightDirection;
  final double shadowAlpha;
  final SceneryKind scenery;

  static ScenePalette resolve(SceneTheme theme, RoadType roadType) {
    final city = roadType == RoadType.city;
    return switch (theme) {
      SceneTheme.clear => ScenePalette(
        skyTop: const Color(0xFF9DBBDD),
        skyHorizon: const Color(0xFFDCE6EE),
        fog: const Color(0xFFDDE6EC),
        fogDensity: city ? 0.010 : 0.0065,
        groundNear: city ? const Color(0xFFB9BEC2) : const Color(0xFFA9BE8A),
        shoulder: const Color(0xFFC3C5C3),
        asphaltNear: const Color(0xFF3F4449),
        asphaltSeam: const Color(0xFF565C62),
        laneWhite: const Color(0xFFF4F6F8),
        laneYellow: const Color(0xFFE2A91B),
        laneBlue: const Color(0xFF4C86E8),
        roadEdge: const Color(0xFFC77B78),
        foliage: const [
          Color(0xFF6E9A66),
          Color(0xFF5C8A57),
          Color(0xFF86AE78),
        ],
        trunk: const Color(0xFF6E5A4A),
        building: const Color(0xFFC9CED3),
        otherVehicle: const Color(0xFFEEF0F2),
        leadVehicle: const Color(0xFF5F7FEA),
        lightDirection: _normalize(-0.35, 0.45, 0.82),
        shadowAlpha: 0.42,
        scenery: city ? SceneryKind.buildings : SceneryKind.trees,
      ),
      SceneTheme.overcast => ScenePalette(
        skyTop: const Color(0xFFD9DDE1),
        skyHorizon: const Color(0xFFE8EAEC),
        fog: const Color(0xFFE6E8EA),
        fogDensity: city ? 0.032 : 0.014,
        groundNear: city ? const Color(0xFFCDD1D4) : const Color(0xFFB4C0A8),
        shoulder: const Color(0xFFD2D5D7),
        asphaltNear: city ? const Color(0xFFBFC4C8) : const Color(0xFF6A7076),
        asphaltSeam: city ? const Color(0xFFB0B5BA) : const Color(0xFF7A8086),
        laneWhite: const Color(0xFFF7F8F9),
        laneYellow: const Color(0xFFD9A93A),
        laneBlue: const Color(0xFF5C8FE0),
        roadEdge: const Color(0xFFC38A87),
        foliage: const [
          Color(0xFF84998A),
          Color(0xFF76897B),
          Color(0xFF93A796),
        ],
        trunk: const Color(0xFF7D7068),
        building: const Color(0xFFD5D8DB),
        otherVehicle: const Color(0xFFE9EBED),
        leadVehicle: const Color(0xFF6C86E6),
        lightDirection: _normalize(-0.1, 0.2, 0.97),
        shadowAlpha: 0.30,
        scenery: city ? SceneryKind.buildings : SceneryKind.trees,
      ),
      SceneTheme.sunset => ScenePalette(
        skyTop: const Color(0xFF3B4A7A),
        skyHorizon: const Color(0xFFF2A26B),
        fog: const Color(0xFFE9A983),
        fogDensity: city ? 0.012 : 0.0075,
        groundNear: city ? const Color(0xFF8A817C) : const Color(0xFF6F7A52),
        shoulder: const Color(0xFF9C918A),
        asphaltNear: const Color(0xFF35373D),
        asphaltSeam: const Color(0xFF46484E),
        laneWhite: const Color(0xFFF3E9DF),
        laneYellow: const Color(0xFFE3A231),
        laneBlue: const Color(0xFF5A86E0),
        roadEdge: const Color(0xFFB86E62),
        foliage: const [
          Color(0xFF5E6E44),
          Color(0xFF4F5E3A),
          Color(0xFF75814D),
        ],
        trunk: const Color(0xFF5A4636),
        building: const Color(0xFFB39C92),
        otherVehicle: const Color(0xFFEDE3DA),
        leadVehicle: const Color(0xFF6C7FE0),
        lightDirection: _normalize(0.92, 0.30, 0.22),
        shadowAlpha: 0.5,
        scenery: city ? SceneryKind.buildings : SceneryKind.trees,
      ),
      SceneTheme.night => ScenePalette(
        skyTop: const Color(0xFF060A14),
        skyHorizon: const Color(0xFF1B2232),
        fog: const Color(0xFF151B27),
        fogDensity: city ? 0.016 : 0.011,
        groundNear: city ? const Color(0xFF1B1D21) : const Color(0xFF161B16),
        shoulder: const Color(0xFF2A2C30),
        asphaltNear: const Color(0xFF1F2125),
        asphaltSeam: const Color(0xFF282A2E),
        laneWhite: const Color(0xFFC9D0D8),
        laneYellow: const Color(0xFFB58A26),
        laneBlue: const Color(0xFF3E66B8),
        roadEdge: const Color(0xFF6E3C3A),
        foliage: const [
          Color(0xFF1E2A22),
          Color(0xFF18231C),
          Color(0xFF243328),
        ],
        trunk: const Color(0xFF231C18),
        building: const Color(0xFF262A33),
        otherVehicle: const Color(0xFF9AA1A9),
        leadVehicle: const Color(0xFF4E66C8),
        lightDirection: _normalize(-0.1, 0.1, 0.99),
        shadowAlpha: 0.26,
        scenery: city ? SceneryKind.buildings : SceneryKind.trees,
      ),
      SceneTheme.rain => ScenePalette(
        skyTop: const Color(0xFF59616C),
        skyHorizon: const Color(0xFF7F8791),
        fog: const Color(0xFF767E87),
        fogDensity: city ? 0.034 : 0.02,
        groundNear: city ? const Color(0xFF6B7076) : const Color(0xFF59624F),
        shoulder: const Color(0xFF7A7F84),
        asphaltNear: const Color(0xFF2D3136),
        asphaltSeam: const Color(0xFF3A3F45),
        laneWhite: const Color(0xFFDDE1E5),
        laneYellow: const Color(0xFFC89B31),
        laneBlue: const Color(0xFF5276C6),
        roadEdge: const Color(0xFF9A6A68),
        foliage: const [
          Color(0xFF4F6B52),
          Color(0xFF445E47),
          Color(0xFF5C785E),
        ],
        trunk: const Color(0xFF4F4540),
        building: const Color(0xFF8A9096),
        otherVehicle: const Color(0xFFD2D6DA),
        leadVehicle: const Color(0xFF5F78DE),
        lightDirection: _normalize(-0.1, 0.2, 0.97),
        shadowAlpha: 0.22,
        scenery: city ? SceneryKind.buildings : SceneryKind.trees,
      ),
    };
  }

  /// Blend [color] toward the fog color for a point [depth] meters away.
  Color fogged(Color color, double depth) {
    final amount = 1 - math.exp(-fogDensity * math.max(0, depth));
    return Color.lerp(color, fog, amount.clamp(0.0, 0.96))!;
  }

  static (double, double, double) _normalize(double x, double y, double z) {
    final length = math.sqrt(x * x + y * y + z * z);
    return (x / length, y / length, z / length);
  }
}

enum SceneryKind { trees, buildings }
