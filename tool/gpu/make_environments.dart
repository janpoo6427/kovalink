// Bakes the image-based lighting for every road-scene theme.
//
//   dart run tool/gpu/make_environments.dart <out-dir>
//
// Writes <out-dir>/<theme>.hdr: an equirectangular Radiance HDR of the
// procedural sky in SceneLook (made by the KovaLink project, CC0-1.0). The
// shell step tool/gpu/make_environments.sh then runs Filament's cmgen on
// them to produce assets/environments/<theme>_ibl.ktx and _skybox.ktx.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:kovalink/src/features/road_view/scene3d/scene_theme.dart';
import 'package:kovalink/src/gpu_scene/scene_look.dart';
import 'package:kovalink/src/models/road_scene.dart';

void main(List<String> args) {
  final out = Directory(args.isEmpty ? 'build/environments' : args.first)
    ..createSync(recursive: true);
  const width = 1024, height = 512;
  for (final theme in SceneTheme.values) {
    final look = SceneLook.resolve(theme, RoadType.highway);
    final pixels = Float32List(width * height * 3);
    for (var v = 0; v < height; v++) {
      final lat = (1 - 2 * (v + 0.5) / height) * math.pi / 2;
      for (var u = 0; u < width; u++) {
        final lon = (2 * (u + 0.5) / width - 1) * math.pi;
        // Filament frame (+Y up) → scene frame (x fwd, y left, z up).
        final fx = math.cos(lat) * math.sin(lon);
        final fy = math.sin(lat);
        final fz = math.cos(lat) * math.cos(lon);
        // The sun disk itself comes from Filament's skybox sun (showSun) so
        // it sits exactly at the light direction; bake only its glow.
        final rgb = look.skyRadiance(-fz, -fx, fy, disk: false);
        final i = (v * width + u) * 3;
        pixels[i] = rgb[0];
        pixels[i + 1] = rgb[1];
        pixels[i + 2] = rgb[2];
      }
    }
    final file = File('${out.path}/${theme.name}.hdr');
    file.writeAsBytesSync(encodeRadianceHdr(width, height, pixels));
    stdout.writeln('wrote ${file.path}');
  }
}

/// Minimal uncompressed (flat RGBE) Radiance HDR encoder.
Uint8List encodeRadianceHdr(int width, int height, Float32List rgb) {
  final header =
      '#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y $height +X $width\n'.codeUnits;
  final body = Uint8List(width * height * 4);
  for (var p = 0; p < width * height; p++) {
    final r = rgb[p * 3], g = rgb[p * 3 + 1], b = rgb[p * 3 + 2];
    final m = math.max(r, math.max(g, b));
    if (m < 1e-32) continue;
    final e = (math.log(m) / math.ln2).floor() + 1;
    final scale = 256 / math.pow(2, e);
    body[p * 4] = (r * scale).floor().clamp(0, 255);
    body[p * 4 + 1] = (g * scale).floor().clamp(0, 255);
    body[p * 4 + 2] = (b * scale).floor().clamp(0, 255);
    body[p * 4 + 3] = e + 128;
  }
  return Uint8List.fromList([...header, ...body]);
}
