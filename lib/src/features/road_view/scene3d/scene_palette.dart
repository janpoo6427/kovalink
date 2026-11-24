import 'dart:math' as math;
import 'dart:ui';

import 'package:kovalink/src/models/road_scene.dart';

/// 맑음 / 흐림 display theme for the road scene (설정 → 화면 테마).
enum SceneTheme { clear, overcast }

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
        fogDensity: city ? 0.024 : 0.014,
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
