import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_camera.dart';
import 'package:kovalink/src/features/road_view/scene3d/scene_director.dart';
import 'package:kovalink/src/models/road_scene.dart';

/// In-scene marks drawn on top of either renderer with the same camera:
/// the lead distance bubble (blue → amber → red as the gap closes) and
/// blind-spot warnings beside the ego. Display only.
class SceneMarkers {
  const SceneMarkers._();

  /// Bubble color for a lead tone 0 (calm) … 1 (close).
  static (Color, Color) bubbleColors(double tone) {
    const calm = (Color(0xFF4A86FF), Color(0xFF2458E0));
    const warn = (Color(0xFFFFB13B), Color(0xFFE48A12));
    const alarm = (Color(0xFFFF5A5F), Color(0xFFD92B3A));
    final t = tone.clamp(0.0, 1.0);
    if (t < 0.5) {
      final u = t * 2;
      return (
        Color.lerp(calm.$1, warn.$1, u)!,
        Color.lerp(calm.$2, warn.$2, u)!,
      );
    }
    final u = t * 2 - 1;
    return (
      Color.lerp(warn.$1, alarm.$1, u)!,
      Color.lerp(warn.$2, alarm.$2, u)!,
    );
  }

  static void paintLeadBubble(
    Canvas canvas,
    SceneCamera camera,
    RoadScene scene, {
    double tone = 0,
    String? fontFamily,
  }) {
    final lead = scene.leadObject;
    if (lead == null || lead.distanceMeters <= 0) return;
    final anchor = camera.project(
      V3(
        lead.distanceMeters + lead.length * 0.4,
        lead.leftMeters,
        lead.height + 0.9,
      ),
    );
    if (anchor == null) return;
    final text = TextPainter(
      text: TextSpan(
        text: '${lead.distanceMeters.toStringAsFixed(1)} m',
        style: TextStyle(
          fontFamily: fontFamily,
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: anchor.offset.translate(0, -text.height / 2 - 8),
      width: text.width + 22,
      height: text.height + 10,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.height / 2),
    );
    final (top, bottom) = bubbleColors(tone);
    canvas.drawRRect(
      rrect.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // Soft halo in the bubble color: reads as light, not a sticker.
    canvas.drawRRect(
      rrect.inflate(3),
      Paint()
        ..color = bottom.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawPath(
      Path()
        ..moveTo(rect.center.dx - 5, rect.bottom - 0.5)
        ..lineTo(rect.center.dx + 5, rect.bottom - 0.5)
        ..lineTo(rect.center.dx, rect.bottom + 6)
        ..close(),
      Paint()..color = bottom,
    );
    text.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
  }

  /// Amber glow on the road beside the ego plus a ring under the car in
  /// the blind spot, fading with [BlindSpotMark.strength].
  static void paintBlindSpots(
    Canvas canvas,
    SceneCamera camera,
    RoadScene scene,
    List<BlindSpotMark> marks, {
    required double egoLength,
    required double egoWidth,
    double timeSeconds = 0,
  }) {
    for (final mark in marks) {
      final side = mark.left ? 1.0 : -1.0;
      final pulse = 0.75 + 0.25 * math.sin(timeSeconds * 2 * math.pi * 1.6);
      final a = (mark.strength * pulse).clamp(0.0, 1.0);
      // Band on the road along the ego's side.
      final y0 = side * (egoWidth / 2 + 0.25),
          y1 = side * (egoWidth / 2 + 1.25);
      final band = camera.projectPolygon([
        V3(-egoLength - 3.5, y0, 0.02),
        V3(0.8, y0, 0.02),
        V3(0.8, y1, 0.02),
        V3(-egoLength - 3.5, y1, 0.02),
      ]);
      if (band != null) {
        final ppm = camera.pixelsPerMeter(
          camera.depthOf(V3(-egoLength / 2, y0, 0)),
        );
        final path = Path()..addPolygon(band, true);
        canvas.drawPath(
          path,
          Paint()
            ..color = Color.fromRGBO(255, 160, 40, 0.42 * a)
            ..blendMode = BlendMode.screen
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              math.max(2.0, ppm * 0.22),
            ),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = Color.fromRGBO(255, 190, 90, 0.5 * a)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.0, ppm * 0.03),
        );
      }
      // Chevrons pointing outward.
      for (var k = 0; k < 3; k++) {
        final x = -egoLength * 0.75 + k * 1.2;
        final c = camera.project(V3(x, side * (egoWidth / 2 + 0.75), 0.03));
        if (c == null) continue;
        final ppm = camera.pixelsPerMeter(c.depth);
        final s = ppm * 0.28;
        final dir = mark.left ? -1.0 : 1.0;
        canvas.drawPath(
          Path()
            ..moveTo(c.offset.dx - dir * s * 0.4, c.offset.dy - s * 0.5)
            ..lineTo(c.offset.dx + dir * s * 0.4, c.offset.dy)
            ..lineTo(c.offset.dx - dir * s * 0.4, c.offset.dy + s * 0.5),
          Paint()
            ..color = Color.fromRGBO(255, 214, 140, 0.9 * a)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = math.max(1.5, s * 0.16),
        );
      }
      // Ring under the other vehicle.
      final o = mark.object;
      if (o != null) {
        final ring = camera.projectPolygon([
          for (var i = 0; i < 28; i++)
            V3(
              o.distanceMeters +
                  o.length / 2 +
                  math.cos(i / 28 * math.pi * 2) * (o.length / 2 + 0.5),
              o.leftMeters +
                  math.sin(i / 28 * math.pi * 2) * (o.width / 2 + 0.45),
              0.02,
            ),
        ]);
        if (ring != null) {
          canvas.drawPath(
            Path()..addPolygon(ring, true),
            Paint()
              ..color = Color.fromRGBO(255, 150, 30, 0.55 * a)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
          );
        }
      }
    }
  }
}

/// Overlay for the GPU path: the same marks the software renderer paints
/// inside its scene, positioned with the director's camera (and roll).
class SceneMarkersPainter extends CustomPainter {
  const SceneMarkersPainter({
    required this.scene,
    required this.frame,
    required this.egoLength,
    required this.egoWidth,
    this.fontFamily,
    this.showLead = true,
  });

  final RoadScene scene;
  final DirectorFrame frame;
  final double egoLength;
  final double egoWidth;
  final String? fontFamily;
  final bool showLead;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    applyRoll(canvas, size, frame.rollRadians, cover: false);
    SceneMarkers.paintBlindSpots(
      canvas,
      frame.camera,
      scene,
      frame.blindSpots,
      egoLength: egoLength,
      egoWidth: egoWidth,
      timeSeconds: scene.monotonicTimeNanos / 1e9,
    );
    if (showLead) {
      SceneMarkers.paintLeadBubble(
        canvas,
        frame.camera,
        scene,
        tone: frame.leadTone,
        fontFamily: fontFamily,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SceneMarkersPainter old) =>
      old.scene != scene || old.frame != frame || old.fontFamily != fontFamily;
}

/// Rotates [canvas] about the screen center by the camera bank angle (the
/// horizon turns the opposite way, as with a real banking camera). With
/// [cover], zooms slightly so a rotated software frame still fills the
/// corners; GPU overlays use `cover: false` to match the 3D camera roll.
void applyRoll(Canvas canvas, Size size, double roll, {bool cover = true}) {
  if (roll == 0) return;
  canvas.translate(size.width / 2, size.height / 2);
  canvas.rotate(roll);
  if (cover) {
    final k =
        1 +
        math.sin(roll.abs()) *
            (size.width + size.height) /
            math.min(size.width, size.height) *
            0.5;
    canvas.scale(k);
  }
  canvas.translate(-size.width / 2, -size.height / 2);
}

/// Falling rain: slanted streaks at three depths plus a faint mist, driven
/// by the scene clock so captures are deterministic.
class RainOverlayPainter extends CustomPainter {
  const RainOverlayPainter({
    required this.timeSeconds,
    this.intensity = 1,
    this.night = false,
  });

  final double timeSeconds;
  final double intensity;
  final bool night;

  static double _hash(int n) {
    var h = (n * 0x27d4eb2d) & 0x7fffffff;
    h = (h ^ (h >> 15)) * 0x2c1b3c6d & 0x7fffffff;
    h = (h ^ (h >> 12)) * 0x297a2d39 & 0x7fffffff;
    return ((h ^ (h >> 15)) & 0xffff) / 0x10000;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0) return;
    final scale = size.shortestSide / 900;
    for (final (layer, count, speed, length, width, alpha) in [
      (0, 110, 1.6, 26.0, 1.0, 0.16),
      (1, 70, 2.2, 42.0, 1.4, 0.20),
      (2, 26, 3.0, 70.0, 2.0, 0.24),
    ]) {
      final paint = Paint()
        ..strokeWidth = width * scale
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < count * intensity; i++) {
        final seed = layer * 1000 + i;
        final x0 = _hash(seed) * (size.width + 200) - 100;
        final phase = _hash(seed + 7);
        final fall = (timeSeconds * speed + phase) % 1.0;
        final y = fall * (size.height + 200) - 100;
        final x = x0 + fall * 60 * scale;
        final l = length * scale * (0.7 + 0.6 * _hash(seed + 13));
        final a = alpha * (0.6 + 0.4 * _hash(seed + 21));
        paint.shader =
            ui.Gradient.linear(Offset(x, y), Offset(x - l * 0.22, y - l), [
              (night ? const Color(0xFFDDE6FF) : Colors.white).withValues(
                alpha: a,
              ),
              Colors.white.withValues(alpha: 0),
            ]);
        canvas.drawLine(Offset(x, y), Offset(x - l * 0.22, y - l), paint);
      }
    }
    // Lower mist where spray from tires hangs above the road.
    final mist = Rect.fromLTWH(
      0,
      size.height * 0.55,
      size.width,
      size.height * 0.45,
    );
    canvas.drawRect(
      mist,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.05 * intensity),
          ],
        ).createShader(mist),
    );
  }

  @override
  bool shouldRepaint(covariant RainOverlayPainter old) =>
      old.timeSeconds != timeSeconds ||
      old.intensity != intensity ||
      old.night != night;
}
