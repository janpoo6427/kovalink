import 'package:flutter/material.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

/// Light glass palette for the driving HUD (reads on bright sky and fog).
abstract final class HudColors {
  static const ink = Color(0xFF15191E);
  static const muted = Color(0xFF7D8791);
  static const faint = Color(0xFFB4BCC4);
  static const glass = Color(0x8CFFFFFF);
  static const cardGlass = Color(0x99E6F0FA);
  static const engaged = Color(0xFF1E9E6A);
  static const engagedTint = Color(0x8C9FE3C6);
  static const signalGreen = Color(0xFF22B455);
  static const signalRed = Color(0xFFE5484D);
  static const signalYellow = Color(0xFFF0A92B);
  static const blue = Color(0xFF2F6BEA);
  static const signGreen = Color(0xFF17643F);
}

/// Driving HUD: every value comes from [scene]; nothing is invented and
/// nothing here sends anything to the vehicle.
class DriveHud extends StatelessWidget {
  const DriveHud({
    required this.scene,
    required this.compact,
    this.unit = SpeedUnit.kph,
    this.showNumbers = true,
    super.key,
  });

  final RoadScene scene;
  final bool compact;
  final SpeedUnit unit;

  /// 설정 → 표시 항목 → HUD 수치 (speed, set speed, limit, info card).
  final bool showNumbers;

  @override
  Widget build(BuildContext context) {
    final tbt = scene.tbt;
    final city = scene.roadType == RoadType.city;
    final showTurnSign =
        tbt != null &&
        tbt.maneuver != TbtManeuver.straight &&
        tbt.maneuver != TbtManeuver.unknown &&
        tbt.distanceMeters <= 1000;
    return DefaultTextStyle.merge(
      style: const TextStyle(color: HudColors.ink),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showNumbers)
            Positioned(
              left: 18,
              top: 14,
              child: SpeedCluster(scene: scene, unit: unit, compact: compact),
            ),
          Positioned(
            top: compact ? (showNumbers ? 146 : 16) : 16,
            left: 0,
            right: 0,
            child: Center(
              child: SignalPill(scene: scene, compact: compact),
            ),
          ),
          if (showNumbers)
            Positioned(
              right: 18,
              top: 14,
              child: SpeedLimitSign(limitKph: scene.speedLimitKph, unit: unit),
            ),
          if (showNumbers)
            Positioned(
              right: 18,
              top: compact ? 204 : 108,
              width: compact ? 250 : 300,
              child: RouteInfoCard(scene: scene, unit: unit, compact: compact),
            ),
          if (showTurnSign && city)
            Positioned(
              right: 18,
              top: compact ? 336 : 252,
              width: compact ? 180 : 210,
              child: TurnSign(instruction: tbt),
            ),
          if (scene.laneGuidance.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: compact ? 84 : 26,
              child: Center(
                child: LaneGuidancePill(
                  lanes: scene.laneGuidance,
                  distanceMeters: tbt?.distanceMeters,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SpeedCluster extends StatelessWidget {
  const SpeedCluster({
    required this.scene,
    required this.unit,
    required this.compact,
    super.key,
  });

  final RoadScene scene;
  final SpeedUnit unit;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final speed = unit.roundedFromMps(scene.speedMps);
    final setSpeed = unit.roundedFromMps(scene.setSpeedMps);
    return Semantics(
      label:
          '현재 속도 $speed ${unit.label}, 기어 ${switch (scene.gear) {
            VehicleGear.park => 'P',
            VehicleGear.reverse => 'R',
            VehicleGear.neutral => 'N',
            VehicleGear.drive => 'D',
            VehicleGear.unknown => '모름',
          }}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$speed',
                style: TextStyle(
                  fontSize: compact ? 64 : 82,
                  height: 0.92,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -3,
                  color: HudColors.ink,
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unit.label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: HudColors.muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GearRow(gear: scene.gear),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Pill(
                tint: scene.engaged ? HudColors.engagedTint : HudColors.glass,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.adjust_rounded,
                      size: 17,
                      color: scene.engaged
                          ? HudColors.engaged
                          : HudColors.muted,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      scene.engaged ? '조향 보조 작동 중' : '조향 보조 대기',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scene.engaged
                            ? const Color(0xFF137A50)
                            : HudColors.ink,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (scene.setSpeedMps > 0)
                _Pill(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '설정',
                        style: TextStyle(fontSize: 12, color: HudColors.muted),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$setSpeed',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class GearRow extends StatelessWidget {
  const GearRow({required this.gear, super.key});

  final VehicleGear gear;

  @override
  Widget build(BuildContext context) {
    const gears = [
      (VehicleGear.park, 'P'),
      (VehicleGear.reverse, 'R'),
      (VehicleGear.neutral, 'N'),
      (VehicleGear.drive, 'D'),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (value, label) in gears)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: value == gear ? 18 : 13,
                fontWeight: value == gear ? FontWeight.w900 : FontWeight.w700,
                color: value == gear ? HudColors.ink : HudColors.faint,
              ),
            ),
          ),
      ],
    );
  }
}

/// Turn signals and the next traffic light (남은 초·거리).
class SignalPill extends StatelessWidget {
  const SignalPill({required this.scene, required this.compact, super.key});

  final RoadScene scene;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final blinkOn = (scene.monotonicTimeNanos ~/ 500000000).isEven;
    Color arrow(bool active) =>
        active && blinkOn ? HudColors.signalGreen : const Color(0x6693D3B0);
    final signal = scene.trafficSignal;
    final distance = signal?.distanceMeters;
    final showSignal = signal != null && (distance == null || distance >= 0);
    return _Pill(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      radius: 22,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.arrow_back_rounded,
            key: const ValueKey('blinker-left'),
            color: arrow(scene.leftBlinker),
            size: 24,
          ),
          SizedBox(width: showSignal ? 14 : (compact ? 44 : 70)),
          if (showSignal) ...[
            TrafficLightGlyph(signal: signal),
            const SizedBox(width: 10),
            if (signal.remainingSeconds != null)
              Text(
                '${signal.remainingSeconds}초',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: switch (signal.state) {
                    TrafficSignalState.red => HudColors.signalRed,
                    TrafficSignalState.yellow => HudColors.signalYellow,
                    _ => HudColors.signalGreen,
                  },
                ),
              ),
            if (distance != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '신호등 ${formatDistance(distance)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: HudColors.muted,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 14),
          ],
          Icon(
            Icons.arrow_forward_rounded,
            key: const ValueKey('blinker-right'),
            color: arrow(scene.rightBlinker),
            size: 24,
          ),
        ],
      ),
    );
  }
}

class TrafficLightGlyph extends StatelessWidget {
  const TrafficLightGlyph({required this.signal, super.key});

  final TrafficSignal signal;

  @override
  Widget build(BuildContext context) {
    Widget lamp(Color? on, {IconData? icon}) => Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ?? const Color(0xFF6E757C),
        boxShadow: on == null
            ? null
            : [BoxShadow(color: on.withValues(alpha: 0.6), blurRadius: 6)],
      ),
      child: icon == null
          ? null
          : Icon(
              icon,
              size: 12,
              color: on == null ? const Color(0xFFA9AFB5) : Colors.white,
            ),
    );
    final state = signal.state;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF3B4147),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          lamp(switch (state) {
            TrafficSignalState.red => HudColors.signalRed,
            TrafficSignalState.yellow => HudColors.signalYellow,
            _ => null,
          }),
          lamp(
            signal.leftArrow ? HudColors.signalGreen : null,
            icon: Icons.arrow_back_rounded,
          ),
          lamp(
            state == TrafficSignalState.green ? HudColors.signalGreen : null,
          ),
        ],
      ),
    );
  }
}

class SpeedLimitSign extends StatelessWidget {
  const SpeedLimitSign({required this.limitKph, required this.unit, super.key});

  final double? limitKph;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final value = limitKph == null ? null : unit.fromKph(limitKph!).round();
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFE0313A), width: 6.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Text(
            value?.toString() ?? '–',
            style: const TextStyle(
              color: Color(0xFF15181C),
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          '제한속도',
          style: TextStyle(
            color: HudColors.muted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Road name, enforcement points, tollgates, next turn and destination.
class RouteInfoCard extends StatelessWidget {
  const RouteInfoCard({
    required this.scene,
    required this.unit,
    this.compact = false,
    super.key,
  });

  final RoadScene scene;
  final SpeedUnit unit;

  /// Phone portrait: the narrower card keeps the smaller type.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tbt = scene.tbt;
    final rows = <Widget>[
      for (final alert in scene.roadAlerts.take(3))
        _InfoRow(
          compact: compact,
          icon: switch (alert.kind) {
            RoadAlertKind.speedCamera => Icons.photo_camera_outlined,
            RoadAlertKind.sectionCamera => Icons.videocam_outlined,
            RoadAlertKind.tollgate => Icons.toll_outlined,
            RoadAlertKind.schoolZone => Icons.school_outlined,
            RoadAlertKind.unknown => Icons.info_outline_rounded,
          },
          label: switch (alert.kind) {
            RoadAlertKind.speedCamera => '과속 카메라',
            RoadAlertKind.sectionCamera => '구간 단속',
            RoadAlertKind.tollgate => '톨게이트',
            RoadAlertKind.schoolZone => '어린이 보호구역',
            RoadAlertKind.unknown => '안내',
          },
          detail: alert.speedLimitKph == null
              ? null
              : '${unit.fromKph(alert.speedLimitKph!).round()} ${unit.label}',
          value: formatDistance(alert.distanceMeters),
        ),
      if (tbt != null &&
          tbt.maneuver != TbtManeuver.straight &&
          tbt.maneuver != TbtManeuver.unknown)
        _InfoRow(
          compact: compact,
          icon: maneuverIcon(tbt.maneuver),
          label: maneuverLabel(tbt.maneuver),
          detail: '교차로',
          value: formatDistance(tbt.distanceMeters),
        ),
      if (tbt?.remainingDistanceMeters case final remaining?)
        _InfoRow(
          compact: compact,
          icon: Icons.flag_outlined,
          label: '목적지까지',
          value:
              '${formatDistance(remaining)}'
              '${tbt!.remainingSeconds == null ? '' : ' · ${formatDuration(tbt.remainingSeconds!)}'}',
        ),
    ];
    if (rows.isEmpty && scene.roadName == null) return const SizedBox.shrink();
    return _Pill(
      radius: 18,
      tint: HudColors.cardGlass,
      padding: compact
          ? const EdgeInsets.fromLTRB(14, 10, 14, 10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scene.roadName case final name?)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                tbt?.roadName ?? name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 11.5 : 12,
                  color: HudColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ...rows,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.compact = false,
  });

  final bool compact;
  final IconData icon;
  final String label;
  final String? detail;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3.5 : 4.5),
      child: Row(
        children: [
          Icon(icon, size: compact ? 17 : 18, color: HudColors.ink),
          SizedBox(width: compact ? 9 : 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12.5 : 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (detail != null)
                  Flexible(
                    child: Text(
                      ' · $detail',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 12.5 : 13,
                        color: HudColors.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 13.5 : 15.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// Green Korean-style turn sign: next maneuver large, the one after small.
class TurnSign extends StatelessWidget {
  const TurnSign({required this.instruction, super.key});

  final TbtInstruction instruction;

  @override
  Widget build(BuildContext context) {
    final next = instruction.nextManeuver;
    final nextDistance = instruction.nextDistanceMeters;
    return Container(
      decoration: BoxDecoration(
        color: HudColors.signGreen,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 12,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Icon(
                  maneuverIcon(instruction.maneuver),
                  color: Colors.white,
                  size: 50,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatDistanceCompact(instruction.distanceMeters),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (next != null && nextDistance != null) ...[
            Divider(
              height: 1,
              thickness: 1,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 12, 8),
              child: Row(
                children: [
                  Icon(maneuverIcon(next), color: Colors.white70, size: 30),
                  const SizedBox(width: 14),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        formatDistanceCompact(nextDistance),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class LaneGuidancePill extends StatelessWidget {
  const LaneGuidancePill({required this.lanes, this.distanceMeters, super.key});

  final List<LaneGuide> lanes;
  final double? distanceMeters;

  @override
  Widget build(BuildContext context) {
    return _Pill(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(10, 8, 18, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final lane in lanes)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
              decoration: BoxDecoration(
                color: lane.recommended
                    ? HudColors.blue
                    : const Color(0x1F15191E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final direction in lane.directions)
                    Icon(
                      switch (direction) {
                        LaneDirection.left => Icons.turn_left_rounded,
                        LaneDirection.right => Icons.turn_right_rounded,
                        LaneDirection.uTurn => Icons.u_turn_left_rounded,
                        LaneDirection.straight => Icons.arrow_upward_rounded,
                      },
                      size: 20,
                      color: lane.recommended ? Colors.white : HudColors.muted,
                    ),
                ],
              ),
            ),
          if (distanceMeters != null) ...[
            const SizedBox(width: 12),
            Text(
              formatDistance(distanceMeters!),
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.child,
    this.tint = HudColors.glass,
    this.radius = 20,
    this.padding = const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
  });

  final Widget child;
  final Color tint;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    radius: radius,
    blur: 16,
    tint: tint,
    padding: padding,
    child: child,
  );
}

IconData maneuverIcon(TbtManeuver maneuver) => switch (maneuver) {
  TbtManeuver.turnLeft => Icons.turn_left_rounded,
  TbtManeuver.turnRight => Icons.turn_right_rounded,
  TbtManeuver.slightLeft => Icons.turn_slight_left_rounded,
  TbtManeuver.slightRight => Icons.turn_slight_right_rounded,
  TbtManeuver.uTurn => Icons.u_turn_left_rounded,
  TbtManeuver.arrive => Icons.flag_rounded,
  _ => Icons.straight_rounded,
};

String maneuverLabel(TbtManeuver maneuver) => switch (maneuver) {
  TbtManeuver.turnLeft => '좌회전',
  TbtManeuver.turnRight => '우회전',
  TbtManeuver.slightLeft => '왼쪽 방향',
  TbtManeuver.slightRight => '오른쪽 방향',
  TbtManeuver.uTurn => '유턴',
  TbtManeuver.arrive => '목적지 도착',
  _ => '직진',
};
