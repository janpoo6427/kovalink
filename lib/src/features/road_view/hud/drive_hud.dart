import 'dart:math' as math;

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
    final showTurnSign =
        scene.roadType == RoadType.city &&
        tbt != null &&
        tbt.maneuver != TbtManeuver.straight &&
        tbt.maneuver != TbtManeuver.unknown &&
        tbt.distanceMeters <= 1000;
    // Bottom parts stay above the home indicator / navigation bar.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) => _buildStack(
        HudLayout(
          box.biggest,
          compact: compact,
          showNumbers: showNumbers,
          bottomInset: bottomInset,
        ),
        turnSign: showTurnSign ? tbt : null,
      ),
    );
  }

  Widget _buildStack(HudLayout layout, {required TbtInstruction? turnSign}) {
    final short = layout.short;
    final small = layout.small;
    return DefaultTextStyle.merge(
      style: const TextStyle(color: HudColors.ink),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showNumbers)
            Positioned(
              left: HudLayout.margin,
              top: HudLayout.speedTop,
              child: short && turnSign != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SpeedCluster(scene: scene, unit: unit, compact: true),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: layout.turnSignWidth,
                          child: TurnSign(
                            instruction: turnSign,
                            showNext: !layout.tight,
                          ),
                        ),
                      ],
                    )
                  : SpeedCluster(scene: scene, unit: unit, compact: small),
            ),
          Positioned.fromRect(
            rect: layout.signalRow,
            child: SignalPill(scene: scene, compact: small),
          ),
          if (showNumbers)
            Positioned(
              right: HudLayout.margin,
              top: HudLayout.speedTop,
              child: SpeedLimitSign(limitKph: scene.speedLimitKph, unit: unit),
            ),
          if (showNumbers)
            Positioned(
              right: HudLayout.margin,
              top: layout.routeCardTop,
              width: layout.routeCardWidth,
              child: RouteInfoCard(scene: scene, unit: unit, compact: small),
            ),
          if (turnSign != null && short && !showNumbers)
            Positioned(
              left: HudLayout.margin,
              top: 16,
              width: layout.turnSignWidth,
              child: TurnSign(instruction: turnSign),
            )
          else if (turnSign != null && !short)
            Positioned(
              right: HudLayout.margin,
              top: layout.turnSignTop,
              width: layout.turnSignWidth,
              child: TurnSign(instruction: turnSign),
            ),
          if (scene.laneGuidance.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: layout.laneBottom,
              child: Center(
                child: LaneGuidancePill(
                  lanes: scene.laneGuidance,
                  distanceMeters: scene.tbt?.distanceMeters,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Room for a road view notice and where in it the notice sits.
typedef NoticeArea = ({Rect area, Alignment alignment});

/// Where the HUD puts its parts on a road view of [size]. Every spot is
/// fixed for a screen shape, so nothing moves when a part comes or goes
/// (a traffic light, the turn sign). The road view uses it too, to keep
/// its own notices clear of the HUD and of [navOverlayZone].
class HudLayout {
  HudLayout(
    this.size, {
    required this.compact,
    required this.showNumbers,
    this.bottomInset = 0,
  }) : short = size.height < 520 && size.width > size.height;

  final Size size;

  /// Narrow road view (phones, small tablets in portrait).
  final bool compact;
  final bool showNumbers;

  /// Home indicator / navigation bar under the road view.
  final double bottomInset;

  /// Landscape phone (car mount): too short for the right-hand column
  /// above the buttons, so the turn sign moves under the speed and the
  /// signal row sits between the speed and the limit sign.
  final bool short;

  static const margin = 18.0;
  static const gap = 12.0;
  static const speedTop = 14.0;

  /// Speed number and pills in their small size.
  static const smallSpeedHeight = 112.0;

  /// Room kept for the turn sign (its rows follow the text size).
  static const turnSignHeight = 120.0;

  /// Room kept for the lane guidance pill.
  static const laneHeight = 50.0;

  /// Smallest room for a notice card on one row (icon beside the text).
  static const minNoticeHeight = 76.0;

  /// Left edge the signal row keeps clear of on wide screens: a 3-digit
  /// speed in the large type with the unit and gear column.
  static const largeSpeedClear = 264.0;

  /// Right edge the signal row keeps clear of: the limit sign.
  static const limitClear = margin + 64 + gap;

  bool get small => compact || short;

  /// Landscape screens too low for the full turn sign under the speed
  /// (Fold cover screen on a mount): the sign drops its second row.
  bool get tight => short && size.height - bottomInset < 330;

  double get signalTop =>
      short ? 16 : (compact ? (showNumbers ? 146 : 16) : 16);

  /// The blinker row: same place and size with or without a traffic
  /// light.
  Rect get signalRow {
    final left = short && showNumbers ? 200.0 : 0.0;
    final right = size.width - (short && showNumbers ? 100.0 : 0.0);
    final width = math.min(SignalPill.width, math.max(0.0, right - left));
    var x = (left + right - width) / 2;
    if (showNumbers && !small) {
      // Same row as the large speed and the limit sign: centered when it
      // clears both, else nudged right of the speed.
      final max = size.width - limitClear - width;
      if (max >= largeSpeedClear) x = x.clamp(largeSpeedClear, max);
    }
    return Rect.fromLTWH(x, signalTop, width, SignalPill.height);
  }

  double get routeCardTop => short ? 108 : (compact ? 204 : 108);
  double get routeCardWidth => short ? 260 : (compact ? 250 : 300);

  /// Room kept for the route card (its height follows the rows).
  double get routeCardHeight => small ? 100 : 116;

  double get turnSignTop => compact ? 336 : 252;

  /// A bit narrower on the narrowest phones, so a notice fits beside it.
  double get turnSignWidth =>
      compact || short ? (size.width < 380 ? 160 : 180) : 210;

  /// Lane guidance pill, from the bottom of the road view.
  double get laneBottom => (compact && !short ? 84 : 26) + bottomInset;

  /// Right middle of the screen: navigation apps (T map and the like)
  /// float their own turn overlay there, over other apps. KovaLink does
  /// not draw it; its notices just stay out of the way.
  Rect get navOverlayZone => Rect.fromLTRB(
    size.width * 0.6,
    size.height * 0.35,
    size.width,
    size.height * 0.65,
  );

  /// Free room for the road view's own notices (camera not connected,
  /// calibration): clear of every HUD part (also the ones not showing
  /// right now), the bottom buttons and [navOverlayZone], plus where in
  /// it the notice sits.
  NoticeArea get noticeArea {
    final bottom = size.height - laneBottom - laneHeight - gap;
    final zone = navOverlayZone;
    if (short) {
      // Between the speed / turn sign column and the route card.
      final top =
          math.max(
            signalRow.bottom,
            showNumbers ? speedTop + smallSpeedHeight : 0,
          ) +
          gap;
      final right =
          math.min(
            showNumbers
                ? size.width - margin - routeCardWidth
                : size.width - margin,
            zone.left,
          ) -
          gap;
      return (
        area: _rect(margin + turnSignWidth + gap, top, right, bottom),
        alignment: Alignment.center,
      );
    }
    // Under the right column (route card, turn sign), above the lane
    // guidance: the notice sits low, below the navigation overlay.
    final under =
        math.max(
          math.max(turnSignTop + turnSignHeight, signalRow.bottom),
          zone.bottom,
        ) +
        gap;
    if (bottom - under >= minNoticeHeight) {
      return (
        area: _rect(margin, under, size.width - margin, bottom),
        alignment: Alignment.bottomCenter,
      );
    }
    // Short screens: left of the turn sign, under the route card.
    final top =
        (showNumbers ? routeCardTop + routeCardHeight : signalRow.bottom) + gap;
    final right =
        math.min(size.width - margin - turnSignWidth, zone.left) - gap;
    return (
      area: _rect(margin, top, right, bottom),
      alignment: Alignment.center,
    );
  }

  static Rect _rect(double left, double top, double right, double bottom) =>
      Rect.fromLTRB(left, top, math.max(left, right), math.max(top, bottom));
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
///
/// The two blinker arrows sit at fixed spots at the ends of the row and
/// the traffic light has its own slot between them, so a light coming
/// up, going away or counting down never moves the arrows.
class SignalPill extends StatelessWidget {
  const SignalPill({required this.scene, required this.compact, super.key});

  final RoadScene scene;
  final bool compact;

  /// The whole row, blinkers included; narrower only if the screen is.
  static const width = 300.0;
  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    final blinkOn = (scene.monotonicTimeNanos ~/ 500000000).isEven;
    Color arrow(bool active) =>
        active && blinkOn ? HudColors.signalGreen : const Color(0x6693D3B0);
    final signal = scene.trafficSignal;
    final distance = signal?.distanceMeters;
    final showSignal = signal != null && (distance == null || distance >= 0);
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        width: math.min(width, box.maxWidth),
        height: math.min(height, box.maxHeight),
        child: Row(
          children: [
            _BlinkerBubble(
              child: Icon(
                Icons.arrow_back_rounded,
                key: const ValueKey('blinker-left'),
                color: arrow(scene.leftBlinker),
                size: 24,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: showSignal
                  ? _Pill(
                      key: const ValueKey('traffic-light-slot'),
                      radius: height / 2,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox.expand(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _TrafficLightRow(signal: signal),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(width: 6),
            _BlinkerBubble(
              child: Icon(
                Icons.arrow_forward_rounded,
                key: const ValueKey('blinker-right'),
                color: arrow(scene.rightBlinker),
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BlinkerBubble extends StatelessWidget {
  const _BlinkerBubble({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _Pill(
    radius: SignalPill.height / 2,
    padding: EdgeInsets.zero,
    child: SizedBox.square(
      dimension: SignalPill.height,
      child: Center(child: child),
    ),
  );
}

/// Light, seconds left and distance, on one line.
class _TrafficLightRow extends StatelessWidget {
  const _TrafficLightRow({required this.signal});

  final TrafficSignal signal;

  @override
  Widget build(BuildContext context) {
    final distance = signal.distanceMeters;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TrafficLightGlyph(signal: signal),
        if (signal.remainingSeconds != null) ...[
          const SizedBox(width: 10),
          Text(
            '${signal.remainingSeconds}초',
            maxLines: 1,
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
        ],
        if (distance != null) ...[
          const SizedBox(width: 8),
          Text(
            '신호등 ${formatDistance(distance)}',
            maxLines: 1,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: HudColors.muted,
            ),
          ),
        ],
      ],
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
  const TurnSign({required this.instruction, this.showNext = true, super.key});

  final TbtInstruction instruction;

  /// The smaller row for the turn after this one.
  final bool showNext;

  @override
  Widget build(BuildContext context) {
    final next = showNext ? instruction.nextManeuver : null;
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
    super.key,
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
