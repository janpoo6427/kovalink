import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';
import 'package:kovalink/src/models/display_units.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/widgets/liquid_glass.dart';

/// Turn-by-turn and automatic lane change cards, bottom right of the
/// drive HUD. Every value comes from the gateway; demo scenes (no
/// `navigation` / `autoLaneChange`) show neither card.
class NavCards extends StatelessWidget {
  const NavCards({
    required this.scene,
    required this.compact,
    this.single = false,
    super.key,
  });

  final RoadScene scene;
  final bool compact;

  /// One card only: the lane change card while a lane change goes on,
  /// else the turn-by-turn card.
  final bool single;

  static const width = 260.0;

  /// The turn-by-turn card is shown (a v2 app with a guide point).
  static bool showsTbt(RoadScene scene) =>
      scene.navigation?.source == NavigationSource.carrotV2 &&
      scene.tbt != null;

  /// The lane change card is shown (setting on, or a lane change going on).
  static bool showsLaneChange(RoadScene scene) {
    final status = scene.autoLaneChange;
    if (status == null) return false;
    return status.setting == AutoLaneChangeSetting.on ||
        status.phase == LaneChangePhase.preLaneChange ||
        status.phase == LaneChangePhase.laneChangeStarting ||
        status.phase == LaneChangePhase.laneChangeFinishing;
  }

  @override
  Widget build(BuildContext context) {
    var tbt = showsTbt(scene) ? scene.tbt : null;
    final laneChange = showsLaneChange(scene) ? scene.autoLaneChange : null;
    if (single && tbt != null && laneChange != null) {
      final changing =
          laneChange.phase != LaneChangePhase.off &&
          laneChange.phase != LaneChangePhase.unknown;
      if (changing) tbt = null;
    }
    final showLaneChange = laneChange != null && (!single || tbt == null);
    if (tbt == null && !showLaneChange) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: width),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (tbt != null)
            TbtCard(tbt: tbt, link: scene.navigation!, compact: compact),
          if (tbt != null && showLaneChange) const SizedBox(height: 8),
          if (showLaneChange) LaneChangeCard(status: laneChange),
        ],
      ),
    );
  }
}

IconData maneuverIcon(TbtManeuver maneuver) => switch (maneuver) {
  TbtManeuver.straight => Icons.straight_rounded,
  TbtManeuver.turnLeft => Icons.turn_left_rounded,
  TbtManeuver.turnRight => Icons.turn_right_rounded,
  TbtManeuver.slightLeft => Icons.turn_slight_left_rounded,
  TbtManeuver.slightRight => Icons.turn_slight_right_rounded,
  TbtManeuver.uTurn => Icons.u_turn_left_rounded,
  TbtManeuver.arrive => Icons.flag_rounded,
  TbtManeuver.unknown => Icons.navigation_rounded,
};

class TbtCard extends StatelessWidget {
  const TbtCard({
    required this.tbt,
    required this.link,
    this.compact = false,
    super.key,
  });

  final TbtInstruction tbt;
  final NavigationLink link;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = tbt.mainText ?? tbt.roadName;
    final next = tbt.nextManeuver;
    final remaining = tbt.remainingDistanceMeters;
    return _Card(
      key: const ValueKey('tbt-card'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                maneuverIcon(tbt.maneuver),
                size: compact ? 30 : 36,
                color: HudColors.blue,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  formatDistance(tbt.distanceMeters),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: HudColors.ink,
                  ),
                ),
              ),
            ],
          ),
          if (text != null && text.isNotEmpty) _Line(text, bold: true),
          if (next != null && tbt.nextDistanceMeters != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _Line('다음'),
                const SizedBox(width: 4),
                Icon(maneuverIcon(next), size: 16, color: HudColors.unit),
                const SizedBox(width: 4),
                _Line(formatDistance(tbt.nextDistanceMeters!)),
              ],
            ),
          if (remaining != null)
            _Line(
              '목적지까지 ${formatDistance(remaining)}'
              '${tbt.remainingSeconds != null ? ' · ${formatDuration(tbt.remainingSeconds!)}' : ''}',
            ),
          _Line(navigationLinkText(link), muted: true),
        ],
      ),
    );
  }
}

/// `TMAP 연결 · 0.3초 전 받음`, plus route state.
String navigationLinkText(NavigationLink link) {
  final age = link.lastReceivedAgeMs;
  final received = age == null
      ? '받은 시각 모름'
      : '${(age / 1000).toStringAsFixed(1)}초 전 받음';
  final state = link.offRoute
      ? ' · 경로 이탈'
      : (link.guidanceActive ? '' : ' · 안내 대기');
  return 'TMAP 연결 · $received$state';
}

/// Korean label of the automatic lane change state.
String laneChangeStateText(AutoLaneChangeStatus status) {
  final side = switch (status.direction) {
    LaneChangeSide.left => '왼쪽 ',
    LaneChangeSide.right => '오른쪽 ',
    null => '',
  };
  switch (status.phase) {
    case LaneChangePhase.off:
      return '대기';
    case LaneChangePhase.preLaneChange:
      return switch (status.auto) {
        AutoLaneChangeAuto.pending => '$side깜빡이 대기 · 곧 자동 변경',
        AutoLaneChangeAuto.waiting => '$side옆 차선 확인 기다림',
        AutoLaneChangeAuto.none => '$side깜빡이 · 핸들을 밀어 주세요',
        _ => '$side깜빡이 켜짐',
      };
    case LaneChangePhase.laneChangeStarting:
    case LaneChangePhase.laneChangeFinishing:
      return status.auto == AutoLaneChangeAuto.returning
          ? '원래 차선으로 되돌아감'
          : '$side차선 변경 중';
    case LaneChangePhase.unknown:
      return '모름';
  }
}

String _blindSpot(bool? value) => switch (value) {
  true => '감지',
  false => '없음',
  null => '모름',
};

class LaneChangeCard extends StatelessWidget {
  const LaneChangeCard({required this.status, super.key});

  final AutoLaneChangeStatus status;

  @override
  Widget build(BuildContext context) {
    final setting = switch (status.setting) {
      AutoLaneChangeSetting.on => '켬',
      AutoLaneChangeSetting.off => '끔',
      AutoLaneChangeSetting.unknown => '모름',
    };
    final fresh = switch (status.blindSpotFresh) {
      true => 'BSM 신호 새로움',
      false => 'BSM 신호 끊김',
      null => 'BSM 신호 모름',
    };
    return _Card(
      key: const ValueKey('lane-change-card'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line('자동 차선 변경 $setting', muted: true),
          _Line(laneChangeStateText(status), bold: true),
          _Line(
            'BSM 왼쪽 ${_blindSpot(status.blindSpotLeft)} · '
            '오른쪽 ${_blindSpot(status.blindSpotRight)}',
          ),
          _Line(fresh, muted: true),
          const _Line('막힌 이유 모름', muted: true),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {this.bold = false, this.muted = false});

  final String text;
  final bool bold;
  final bool muted;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: bold ? 15 : 13,
      fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
      color: muted ? HudColors.unit : HudColors.ink,
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => LiquidGlass(
    radius: 16,
    blur: 16,
    tint: HudColors.cardGlass,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: child,
  );
}
