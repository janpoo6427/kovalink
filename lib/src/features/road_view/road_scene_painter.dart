import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kovalink/src/models/ego_vehicle_profile.dart';
import 'package:kovalink/src/models/road_scene.dart';

class RoadScenePainter extends CustomPainter {
  const RoadScenePainter(
    this.scene, {
    this.drawEnvironment = true,
    this.cameraAligned = false,
    this.drawEgoVehicle = false,
    this.vehicle = EgoVehicleProfile.builtIn,
  });

  final RoadScene scene;
  final bool drawEnvironment;
  final bool cameraAligned;
  final bool drawEgoVehicle;

  /// Size and colors of the built-in ego renderer (from the model pack).
  final EgoVehicleProfile vehicle;
  static const maxDistanceMeters = 120.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (drawEnvironment) {
      _paintBackground(canvas, size);
      _paintRoadGrid(canvas, size);
    }
    _paintPolyline(canvas, size, scene.leftLane, const Color(0xB8EEF5F8), 2.2);
    _paintPolyline(canvas, size, scene.rightLane, const Color(0xB8EEF5F8), 2.2);
    _paintPath(canvas, size);
    for (final object in scene.objects.reversed) {
      _paintObject(canvas, size, object);
    }
    if (drawEnvironment) {
      _paintVehicleSignals(canvas, size);
      if (drawEgoVehicle) _paintFallbackVehicle(canvas, size);
    }
  }

  void _paintBackground(Canvas canvas, Size size) {
    final horizon = size.height * 0.22;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF253447), Color(0xFF101A26), Color(0xFF070B11)],
          stops: [0, 0.32, 1],
        ).createShader(Offset.zero & size),
    );
    canvas.drawCircle(
      Offset(size.width * 0.78, horizon * 0.5),
      size.width * 0.08,
      Paint()..color = const Color(0x18C9E7FF),
    );
  }

  void _paintRoadGrid(Canvas canvas, Size size) {
    final road = Path()
      ..moveTo(size.width * 0.44, size.height * 0.22)
      ..lineTo(size.width * 0.02, size.height)
      ..lineTo(size.width * 0.98, size.height)
      ..lineTo(size.width * 0.56, size.height * 0.22)
      ..close();
    canvas.drawPath(
      road,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF23303C), Color(0xFF11171E)],
        ).createShader(Offset.zero & size),
    );
    final shoulderPaint = Paint()
      ..color = const Color(0x5574838F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    final leftShoulder = Path()
      ..moveTo(size.width * 0.41, size.height * 0.22)
      ..quadraticBezierTo(
        size.width * 0.27,
        size.height * 0.60,
        size.width * 0.02,
        size.height,
      );
    final rightShoulder = Path()
      ..moveTo(size.width * 0.59, size.height * 0.22)
      ..quadraticBezierTo(
        size.width * 0.73,
        size.height * 0.60,
        size.width * 0.98,
        size.height,
      );
    canvas.drawPath(leftShoulder, shoulderPaint);
    canvas.drawPath(rightShoulder, shoulderPaint);
    final gridPaint = Paint()
      ..color = const Color(0x1F8DA4B5)
      ..strokeWidth = 1;
    for (var distance = 10.0; distance <= 100; distance += 10) {
      canvas.drawLine(
        _project(size, ScenePoint(forwardMeters: distance, leftMeters: 7)),
        _project(size, ScenePoint(forwardMeters: distance, leftMeters: -7)),
        gridPaint,
      );
    }
  }

  void _paintVehicleSignals(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.86);
    if (scene.brakeActive) {
      canvas.drawOval(
        Rect.fromCenter(
          center: center.translate(0, size.height * 0.055),
          width: size.width * 0.38,
          height: size.height * 0.10,
        ),
        Paint()
          ..shader =
              const RadialGradient(
                colors: [Color(0x99FF334C), Color(0x00FF334C)],
              ).createShader(
                Rect.fromCenter(
                  center: center,
                  width: size.width * 0.38,
                  height: size.height * 0.12,
                ),
              ),
      );
    }

    if (scene.gear == VehicleGear.reverse) {
      final turn = (scene.steeringAngleDegrees / 32).clamp(-1.0, 1.0);
      final path = Path()..moveTo(center.dx, center.dy + size.height * 0.08);
      path.quadraticBezierTo(
        center.dx - turn * size.width * 0.20,
        size.height * 0.95,
        center.dx - turn * size.width * 0.34,
        size.height * 1.08,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xCC72A7FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    }

    final blinkOn = (scene.monotonicTimeNanos ~/ 500000000).isEven;
    if (!blinkOn) return;
    final lampY = center.dy + size.height * 0.012;
    if (scene.leftBlinker) {
      _paintLampGlow(canvas, Offset(center.dx - size.width * 0.105, lampY));
    }
    if (scene.rightBlinker) {
      _paintLampGlow(canvas, Offset(center.dx + size.width * 0.105, lampY));
    }
  }

  void _paintLampGlow(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      26,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFFFB21C), Color(0x00FFB21C)],
        ).createShader(Rect.fromCircle(center: center, radius: 26)),
    );
  }

  /// Screen rectangle of the chase-view ego body. Public for tests.
  static Rect chaseEgoBodyRect(Size size, EgoVehicleProfile vehicle) {
    final center = Offset(size.width / 2, size.height * 0.86);
    final width = math.min(size.width * 0.38, 205.0) * vehicle.chaseWidthScale;
    final height = width * vehicle.chaseHeightRatio;
    return Rect.fromCenter(center: center, width: width, height: height);
  }

  void _paintFallbackVehicle(Canvas canvas, Size size) {
    final bodyRect = chaseEgoBodyRect(size, vehicle);
    final center = bodyRect.center;
    final width = bodyRect.width;
    final height = bodyRect.height;
    final paintColor = Color(vehicle.appearance.paintArgb);
    final glassColor = Color(vehicle.appearance.glassArgb);
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(0, height * 0.36),
        width: width * 1.12,
        height: height * 0.45,
      ),
      Paint()
        ..shader =
            const RadialGradient(
              colors: [Color(0x99000000), Color(0x00000000)],
            ).createShader(
              Rect.fromCenter(
                center: center,
                width: width * 1.12,
                height: height * 0.55,
              ),
            ),
    );

    final body = Path()
      ..moveTo(center.dx - width * 0.47, center.dy + height * 0.30)
      ..quadraticBezierTo(
        center.dx - width * 0.51,
        center.dy,
        center.dx - width * 0.34,
        center.dy - height * 0.38,
      )
      ..quadraticBezierTo(
        center.dx,
        center.dy - height * 0.62,
        center.dx + width * 0.34,
        center.dy - height * 0.38,
      )
      ..quadraticBezierTo(
        center.dx + width * 0.51,
        center.dy,
        center.dx + width * 0.47,
        center.dy + height * 0.30,
      )
      ..quadraticBezierTo(
        center.dx,
        center.dy + height * 0.52,
        center.dx - width * 0.47,
        center.dy + height * 0.30,
      )
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(paintColor, Colors.white, 0.6)!,
                paintColor,
                Color.lerp(paintColor, Colors.black, 0.56)!,
              ],
              stops: const [0, 0.48, 1],
            ).createShader(
              Rect.fromCenter(center: center, width: width, height: height),
            ),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = const Color(0x8095A3AF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    final rearGlass = Path()
      ..moveTo(center.dx - width * 0.27, center.dy - height * 0.25)
      ..quadraticBezierTo(
        center.dx,
        center.dy - height * 0.46,
        center.dx + width * 0.27,
        center.dy - height * 0.25,
      )
      ..lineTo(center.dx + width * 0.32, center.dy + height * 0.02)
      ..quadraticBezierTo(
        center.dx,
        center.dy + height * 0.10,
        center.dx - width * 0.32,
        center.dy + height * 0.02,
      )
      ..close();
    canvas.drawPath(
      rearGlass,
      Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [glassColor, Color.lerp(glassColor, Colors.black, 0.62)!],
            ).createShader(
              Rect.fromCenter(center: center, width: width, height: height),
            ),
    );
    final red = scene.brakeActive
        ? const Color(0xFFFF3B50)
        : Color(vehicle.appearance.lampArgb);
    final lightPaint = Paint()
      ..color = red
      ..strokeWidth = scene.brakeActive ? 7 : 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center.translate(-width * 0.34, height * 0.25),
      center.translate(-width * 0.08, height * 0.30),
      lightPaint,
    );
    canvas.drawLine(
      center.translate(width * 0.08, height * 0.30),
      center.translate(width * 0.34, height * 0.25),
      lightPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center.translate(0, height * 0.34),
          width: width * 0.25,
          height: height * 0.08,
        ),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFFE9EDF0),
    );
  }

  void _paintPath(Canvas canvas, Size size) {
    if (scene.plannedPath.length < 2) return;
    final polygon = Path();
    var started = false;
    final points = [
      ...scene.plannedPath.map(
        (point) => ScenePoint(
          forwardMeters: point.forwardMeters,
          leftMeters: point.leftMeters + 0.85,
        ),
      ),
      ...scene.plannedPath.reversed.map(
        (point) => ScenePoint(
          forwardMeters: point.forwardMeters,
          leftMeters: point.leftMeters - 0.85,
        ),
      ),
    ];
    for (final point in points) {
      final projected = _project(size, point);
      if (!started) {
        polygon.moveTo(projected.dx, projected.dy);
        started = true;
      } else {
        polygon.lineTo(projected.dx, projected.dy);
      }
    }
    polygon.close();
    canvas.drawPath(
      polygon,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x3058F2C2), Color(0xD858F2C2)],
        ).createShader(Offset.zero & size),
    );
  }

  void _paintPolyline(
    Canvas canvas,
    Size size,
    List<ScenePoint> points,
    Color color,
    double width,
  ) {
    if (points.length < 2) return;
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final projected = _project(size, points[index]);
      index == 0
          ? path.moveTo(projected.dx, projected.dy)
          : path.lineTo(projected.dx, projected.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintObject(Canvas canvas, Size size, TrackedObject object) {
    if (object.distanceMeters <= 0 ||
        object.distanceMeters > maxDistanceMeters) {
      return;
    }
    final center = _project(
      size,
      ScenePoint(
        forwardMeters: object.distanceMeters,
        leftMeters: object.leftMeters,
      ),
    );
    final depth = (1 - object.distanceMeters / maxDistanceMeters).clamp(
      0.0,
      1.0,
    );
    final width = size.width * (0.045 + depth * 0.13);
    final height = width * 0.82;
    final approaching = object.relativeSpeedMps < -0.3;
    final color = approaching
        ? const Color(0xFFFF7B72)
        : const Color(0xFF72A7FF);
    final carCenter = center.translate(0, -height * 0.42);
    final shadowRect = Rect.fromCenter(
      center: carCenter.translate(0, height * 0.42),
      width: width * 1.2,
      height: height * 0.34,
    );
    canvas.drawOval(
      shadowRect,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.black.withValues(alpha: 0.48), Colors.transparent],
        ).createShader(shadowRect),
    );
    final body = Path()
      ..moveTo(carCenter.dx - width * 0.48, carCenter.dy + height * 0.42)
      ..lineTo(carCenter.dx - width * 0.37, carCenter.dy - height * 0.18)
      ..lineTo(carCenter.dx - width * 0.23, carCenter.dy - height * 0.49)
      ..lineTo(carCenter.dx + width * 0.23, carCenter.dy - height * 0.49)
      ..lineTo(carCenter.dx + width * 0.37, carCenter.dy - height * 0.18)
      ..lineTo(carCenter.dx + width * 0.48, carCenter.dy + height * 0.42)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader =
            LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color.withValues(alpha: 0.95), const Color(0xFF27313B)],
            ).createShader(
              Rect.fromCenter(center: carCenter, width: width, height: height),
            ),
    );
    final glass = Path()
      ..moveTo(carCenter.dx - width * 0.20, carCenter.dy - height * 0.40)
      ..lineTo(carCenter.dx + width * 0.20, carCenter.dy - height * 0.40)
      ..lineTo(carCenter.dx + width * 0.29, carCenter.dy - height * 0.08)
      ..lineTo(carCenter.dx - width * 0.29, carCenter.dy - height * 0.08)
      ..close();
    canvas.drawPath(glass, Paint()..color = const Color(0xD9101B26));
    final tailPaint = Paint()
      ..color = approaching ? const Color(0xFFFF3D51) : color
      ..strokeWidth = math.max(2, width * 0.07)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      carCenter.translate(-width * 0.36, height * 0.28),
      carCenter.translate(-width * 0.10, height * 0.32),
      tailPaint,
    );
    canvas.drawLine(
      carCenter.translate(width * 0.10, height * 0.32),
      carCenter.translate(width * 0.36, height * 0.28),
      tailPaint,
    );
    final label = TextPainter(
      text: TextSpan(
        text: '${object.distanceMeters.round()} m',
        style: TextStyle(
          color: color,
          fontSize: math.max(10, width * 0.18),
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(
      canvas,
      Offset(
        center.dx - label.width / 2,
        carCenter.dy - height * 0.58 - label.height,
      ),
    );
  }

  Offset _project(Size size, ScenePoint point) {
    final projection = scene.cameraProjection;
    if (cameraAligned && projection != null) {
      final matrix = projection.matrix;
      final x = point.forwardMeters;
      final y = point.leftMeters;
      final z = point.upMeters;
      final denominator =
          matrix[8] * x + matrix[9] * y + matrix[10] * z + matrix[11];
      if (denominator.abs() > 1e-6) {
        final sourceX =
            (matrix[0] * x + matrix[1] * y + matrix[2] * z + matrix[3]) /
            denominator;
        final sourceY =
            (matrix[4] * x + matrix[5] * y + matrix[6] * z + matrix[7]) /
            denominator;
        final coverScale = math.max(
          size.width / projection.sourceWidth,
          size.height / projection.sourceHeight,
        );
        final offsetX = (size.width - projection.sourceWidth * coverScale) / 2;
        final offsetY =
            (size.height - projection.sourceHeight * coverScale) / 2;
        return Offset(
          offsetX + sourceX * coverScale,
          offsetY + sourceY * coverScale,
        );
      }
    }
    final normalized = (point.forwardMeters / maxDistanceMeters).clamp(
      0.0,
      1.0,
    );
    final horizon = size.height * 0.22;
    final bottom = size.height * 0.98;
    final y = bottom - (bottom - horizon) * math.pow(normalized, 0.68);
    final pixelsPerMeter = size.width * (0.025 + (1 - normalized) * 0.055);
    return Offset(size.width / 2 - point.leftMeters * pixelsPerMeter, y);
  }

  @override
  bool shouldRepaint(covariant RoadScenePainter oldDelegate) =>
      oldDelegate.scene.monotonicTimeNanos != scene.monotonicTimeNanos ||
      oldDelegate.drawEnvironment != drawEnvironment ||
      oldDelegate.cameraAligned != cameraAligned ||
      oldDelegate.drawEgoVehicle != drawEgoVehicle ||
      oldDelegate.vehicle != vehicle;
}
