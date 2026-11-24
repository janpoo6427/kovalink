import 'dart:math' as math;

import 'package:kovalink/src/features/road_view/scene3d/scene_theme.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// Lighting, sky, fog and weather of one [SceneTheme] for the GPU (Filament)
/// renderer. The same procedural sky also bakes the image-based lighting
/// assets (tool/gpu/make_environments.dart), so reflections match the sky.
///
/// Units: sky radiance is relative (baked into the IBL and multiplied by
/// [iblIntensity]); the camera exposure is solved so the horizon lands at
/// [horizonTarget] on screen. Punctual lights are given as on-screen
/// levels and converted with that exposure, so night and rain keep their
/// intended brightness whatever the sky level is.
///
/// Directions use the road-scene frame: x forward, y left, z up.
class SceneLook {
  const SceneLook({
    required this.theme,
    required this.zenith,
    required this.horizon,
    required this.ground,
    required this.sunDirection,
    required this.sunColor,
    required this.sunLux,
    required this.sunDiskRadiance,
    required this.sunGlow,
    required this.iblIntensity,
    required this.horizonTarget,
    required this.fogTint,
    required this.fogDensity,
    required this.fogStart,
    required this.headlights,
    required this.wetness,
    required this.streetLights,
    required this.bloom,
    required this.rain,
    this.horizonGlow = const [0, 0, 0],
    this.cityGlow = 0,
    this.headlightLevel = 0,
    this.lampLevel = 0,
  });

  final SceneTheme theme;

  /// Linear sky radiance (relative units) straight up / at the horizon.
  final List<double> zenith;
  final List<double> horizon;

  /// Linear radiance of the ground seen in the environment map.
  final List<double> ground;

  /// Unit vector toward the sun (scene frame).
  final (double, double, double) sunDirection;
  final List<double> sunColor;
  final double sunLux;

  /// Relative radiance of the sun disk and its glow in the environment.
  final double sunDiskRadiance;
  final double sunGlow;

  /// Extra warm glow along the horizon toward the sun (sunset).
  final List<double> horizonGlow;

  /// Light-pollution glow near the horizon (night city).
  final double cityGlow;

  /// Filament IBL (and skybox) intensity for the baked environment.
  final double iblIntensity;

  /// On-screen value (before tone mapping) of the horizon sky.
  final double horizonTarget;

  /// Fog color as a multiple of the horizon radiance (1 = same as sky).
  final double fogTint;

  /// Fog density per meter (Filament fog).
  final double fogDensity;
  final double fogStart;

  /// Vehicles drive with headlights on.
  final bool headlights;

  /// 0 = dry asphalt, 1 = soaked (mirror-like puddles).
  final double wetness;

  /// Lit street lamps along the road.
  final bool streetLights;
  final double bloom;

  /// Falling rain overlay.
  final bool rain;

  /// On-screen brightness of road lit by headlights / street lamps.
  final double headlightLevel;
  final double lampLevel;

  /// Base name of the baked IBL asset (`assets/environments/NAME_ibl.ktx`).
  String get environmentName => theme.name;

  bool get night => theme == SceneTheme.night;

  double get _horizonLuminance =>
      0.2126 * horizon[0] +
      0.7152 * horizon[1] +
      0.0722 * horizon[2] +
      cityGlow * 0.7 +
      horizonGlow[0] * 0.25;

  /// Filament exposure factor (1 / (1.2 · 2^EV100)).
  double get exposure => horizonTarget / (iblIntensity * _horizonLuminance);

  /// Camera exposure, EV at ISO 100.
  double get ev100 => math.log(1 / (1.2 * exposure)) / math.ln2;

  /// Linear fog color in Filament units (multiplied by the IBL luminance).
  List<double> get fogColor => [for (final c in horizon) c * fogTint];

  /// Luminous power of one headlight / street lamp, lumens.
  double get headlightLumens => headlightLevel / exposure * 950;
  double get lampLumens => lampLevel / exposure * 2100;

  static SceneLook resolve(SceneTheme theme, RoadType roadType) {
    final city = roadType == RoadType.city;
    return switch (theme) {
      SceneTheme.clear => SceneLook(
        theme: theme,
        zenith: const [0.13, 0.30, 0.78],
        horizon: const [0.74, 0.84, 0.96],
        ground: const [0.22, 0.24, 0.20],
        sunDirection: _unit(-0.42, 0.38, 0.82),
        sunColor: const [1.0, 0.97, 0.92],
        sunLux: 100000,
        sunDiskRadiance: 900,
        sunGlow: 1.6,
        iblIntensity: 30000,
        horizonTarget: 0.86,
        fogTint: 0.95,
        fogDensity: city ? 0.005 : 0.0032,
        fogStart: 40,
        headlights: false,
        wetness: 0,
        streetLights: false,
        bloom: 0.06,
        rain: false,
      ),
      SceneTheme.overcast => SceneLook(
        theme: theme,
        zenith: const [0.60, 0.63, 0.68],
        horizon: const [0.80, 0.82, 0.84],
        ground: const [0.26, 0.27, 0.27],
        sunDirection: _unit(-0.2, 0.25, 0.95),
        sunColor: const [0.95, 0.97, 1.0],
        sunLux: 18000,
        sunDiskRadiance: 0,
        sunGlow: 0.25,
        iblIntensity: 30000,
        horizonTarget: 0.9,
        fogTint: 1.0,
        fogDensity: city ? 0.012 : 0.007,
        fogStart: 18,
        headlights: false,
        wetness: 0.15,
        streetLights: false,
        bloom: 0.05,
        rain: false,
      ),
      SceneTheme.sunset => SceneLook(
        theme: theme,
        zenith: const [0.12, 0.16, 0.40],
        horizon: const [1.0, 0.52, 0.28],
        ground: const [0.12, 0.09, 0.08],
        sunDirection: _unit(0.92, 0.30, 0.10),
        sunColor: const [1.0, 0.56, 0.28],
        sunLux: 38000,
        sunDiskRadiance: 260,
        sunGlow: 4.0,
        horizonGlow: const [1.2, 0.42, 0.14],
        iblIntensity: 16000,
        horizonTarget: 0.95,
        fogTint: 0.8,
        fogDensity: city ? 0.007 : 0.0045,
        fogStart: 30,
        headlights: true,
        wetness: 0,
        streetLights: false,
        bloom: 0.12,
        rain: false,
        headlightLevel: 0.25,
      ),
      SceneTheme.night => SceneLook(
        theme: theme,
        zenith: const [0.004, 0.007, 0.018],
        horizon: const [0.030, 0.034, 0.050],
        ground: const [0.010, 0.010, 0.012],
        sunDirection: _unit(-0.3, -0.4, 0.86),
        sunColor: const [0.62, 0.72, 1.0],
        sunLux: 0,
        sunDiskRadiance: 0,
        sunGlow: 0,
        cityGlow: city ? 0.10 : 0.05,
        iblIntensity: 110,
        horizonTarget: 0.12,
        fogTint: 0.6,
        fogDensity: city ? 0.010 : 0.007,
        fogStart: 20,
        headlights: true,
        wetness: 0.1,
        streetLights: true,
        bloom: 0.22,
        rain: false,
        headlightLevel: 1.0,
        lampLevel: 0.55,
      ),
      SceneTheme.rain => SceneLook(
        theme: theme,
        zenith: const [0.30, 0.33, 0.38],
        horizon: const [0.45, 0.48, 0.52],
        ground: const [0.10, 0.11, 0.12],
        sunDirection: _unit(-0.1, 0.2, 0.97),
        sunColor: const [0.85, 0.90, 1.0],
        sunLux: 2500,
        sunDiskRadiance: 0,
        sunGlow: 0,
        cityGlow: city ? 0.04 : 0.0,
        iblIntensity: 8000,
        horizonTarget: 0.48,
        fogTint: 0.95,
        fogDensity: city ? 0.016 : 0.011,
        fogStart: 10,
        headlights: true,
        wetness: 1.0,
        streetLights: city,
        bloom: 0.2,
        rain: true,
        headlightLevel: 0.5,
        lampLevel: 0.3,
      ),
    };
  }

  /// Sky radiance (linear, relative) seen along unit direction [d] in the
  /// scene frame. Used to bake the environment map.
  List<double> skyRadiance(
    double dx,
    double dy,
    double dz, {
    bool disk = true,
  }) {
    final (sx, sy, sz) = sunDirection;
    if (dz < 0) {
      // Ground: darker toward the nadir, slight horizon haze.
      final t = math.pow(1 - (-dz).clamp(0.0, 1.0), 6).toDouble();
      return [
        for (var i = 0; i < 3; i++)
          ground[i] + (horizon[i] - ground[i]) * t * 0.6,
      ];
    }
    final up = dz.clamp(0.0, 1.0);
    final t = math.pow(1 - up, 3.2).toDouble();
    final out = [
      for (var i = 0; i < 3; i++) zenith[i] + (horizon[i] - zenith[i]) * t,
    ];
    final cosSun = (dx * sx + dy * sy + dz * sz).clamp(-1.0, 1.0);
    // Wide glow around the sun and a warm band along the horizon.
    if (sunGlow > 0) {
      final glow = math.pow((cosSun + 1) / 2, 24).toDouble() * sunGlow;
      for (var i = 0; i < 3; i++) {
        out[i] += sunColor[i] * glow;
      }
    }
    if (horizonGlow.any((v) => v > 0)) {
      final toward = math.pow((cosSun + 1) / 2, 3).toDouble();
      final band = math.pow(1 - up, 9).toDouble() * toward;
      for (var i = 0; i < 3; i++) {
        out[i] += horizonGlow[i] * band;
      }
    }
    if (cityGlow > 0) {
      final band = math.pow(1 - up, 14).toDouble() * cityGlow;
      out[0] += band * 1.0;
      out[1] += band * 0.62;
      out[2] += band * 0.34;
    }
    // Sun disk (about 0.6° radius, soft edge).
    if (disk && sunDiskRadiance > 0 && cosSun > 0.99990) {
      final edge = ((cosSun - 0.99990) / 0.00006).clamp(0.0, 1.0);
      for (var i = 0; i < 3; i++) {
        out[i] += sunColor[i] * sunDiskRadiance * edge;
      }
    }
    return out;
  }

  static (double, double, double) _unit(double x, double y, double z) {
    final l = math.sqrt(x * x + y * y + z * z);
    return (x / l, y / l, z / l);
  }
}
