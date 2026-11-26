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

  /// Light ring around the speed and its unit, so the dark digits also
  /// read on a dark road view (night, no camera). On a bright sky it
  /// melts into the background.
  static const halo = Color(0xF2FFFFFF);

  /// The unit beside the speed (km/h, mph): darker than [muted] so it
  /// keeps 4.5:1 on white and on its [halo].
  static const unit = Color(0xFF5A636D);

  /// Gear capsule: dark, so P R N D read on a bright sky, a white
  /// building or snow. The light edge keeps its outline on a dark view.
  static const gearPlate = Color(0xD91A1F25);
  static const gearPlateEdge = Color(0x40FFFFFF);
  static const gearOn = Color(0xFFFFFFFF);
  static const gearOff = Color(0xFFB8C0C8);
}

/// [HudColors.halo] as a thin outline [radius] wide plus a soft glow.
List<Shadow> _halo(double radius) => [
  for (final (dx, dy) in const [
    (1.0, 0.0),
    (-1.0, 0.0),
    (0.0, 1.0),
    (0.0, -1.0),
    (0.7071, 0.7071),
    (0.7071, -0.7071),
    (-0.7071, 0.7071),
    (-0.7071, -0.7071),
  ])
    Shadow(
      color: HudColors.halo,
      offset: Offset(dx * radius, dy * radius),
      blurRadius: radius * 0.6,
    ),
  Shadow(color: HudColors.halo.withValues(alpha: 0.55), blurRadius: radius * 3),
];

/// Text widths measured the way a [Text] here lays out (default text
/// style, text scale, bold-text setting), for boxes that must keep their
/// size whatever text they show.
abstract final class HudText {
  static final _widths = <Object, double>{};
  static var _watchingFonts = false;

  /// Widest of [samples] in [style], rounded up to a whole pixel.
  static double widest(
    BuildContext context,
    TextStyle style,
    List<String> samples,
  ) {
    var effective = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final scaler = MediaQuery.textScalerOf(context);
    if (!_watchingFonts) {
      // A font that finishes loading later changes the widths.
      PaintingBinding.instance.systemFonts.addListener(_widths.clear);
      _watchingFonts = true;
    }
    if (_widths.length > 64) _widths.clear();
    return _widths[(effective, scaler, samples.join('\u0000'))] ??= _measure(
      effective,
      scaler,
      samples,
    );
  }

  static double _measure(
    TextStyle style,
    TextScaler scaler,
    List<String> samples,
  ) {
    var widest = 0.0;
    for (final sample in samples) {
      final painter = TextPainter(
        text: TextSpan(text: sample, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return widest.ceilToDouble();
  }
}

/// Driving HUD: every value comes from [scene]; nothing is invented and
/// nothing here sends anything to the vehicle.
///
/// No turn-by-turn guidance is drawn (no turn sign, route card or lane
/// guidance): kovapilot sends none, so it only ever showed the demo's
/// made-up values. [RoadScene] still reads those fields.
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

  /// 설정 → 표시 항목 → 속도와 제한속도 (speed, set speed, limit).
  final bool showNumbers;

  @override
  Widget build(BuildContext context) {
    // Notices stay above the home indicator / navigation bar.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return DefaultTextStyle.merge(
      style: const TextStyle(color: HudColors.ink),
      child: LayoutBuilder(
        builder: (context, box) {
          final small = compact || HudLayout.isShort(box.biggest);
          return _buildStack(
            HudLayout(
              box.biggest,
              compact: compact,
              showNumbers: showNumbers,
              bottomInset: bottomInset,
              // The same for every speed (a 3-digit box).
              speedRowRight: showNumbers
                  ? HudLayout.margin +
                        SpeedCluster.rowWidth(
                          context,
                          compact: small,
                          unit: unit,
                        )
                  : 0,
            ),
          );
        },
      ),
    );
  }

  Widget _buildStack(HudLayout layout) {
    final small = layout.small;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final left in [true, false])
          if (left ? scene.leftBlindspot : scene.rightBlindspot)
            Align(
              alignment: left ? Alignment.centerLeft : Alignment.centerRight,
              child: Semantics(
                label: left ? "왼쪽 사각지대 경고" : "오른쪽 사각지대 경고",
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                  size: 28,
                ),
              ),
            ),
        if (showNumbers)
          Positioned(
            left: HudLayout.margin,
            top: HudLayout.speedTop,
            child: SpeedCluster(scene: scene, unit: unit, compact: small),
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
      ],
    );
  }
}

/// Room for a road view notice and where in it the notice sits.
typedef NoticeArea = ({Rect area, Alignment alignment});

/// Where the HUD puts its parts on a road view of [size]. Every spot is
/// fixed for a screen shape, so nothing moves when a part comes or goes
/// (a traffic light). The road view uses it too, to keep its own notices
/// clear of the HUD, the bottom buttons and [navOverlayZone].
class HudLayout {
  HudLayout(
    this.size, {
    required this.compact,
    required this.showNumbers,
    this.bottomInset = 0,
    this.speedRowRight = 0,
  }) : short = isShort(size);

  /// Landscape phone shape (see [short]).
  static bool isShort(Size size) =>
      size.height < 520 && size.width > size.height;

  final Size size;

  /// Narrow road view (phones, small tablets in portrait).
  final bool compact;
  final bool showNumbers;

  /// Home indicator / navigation bar under the road view.
  final double bottomInset;

  /// Landscape phone (car mount): the signal row sits between the speed
  /// and the limit sign, and notices go left of [navOverlayZone].
  final bool short;

  /// Right edge of the speed number row (number, unit and gear column:
  /// [margin] plus [SpeedCluster.rowWidth]). It does not change with the
  /// speed. The signal row keeps clear of it where it is wider than the
  /// fixed clearances below (large text). 0: only the fixed clearances.
  final double speedRowRight;

  static const margin = 18.0;
  static const gap = 12.0;
  static const speedTop = 14.0;

  /// Speed number and pills in their small size.
  static const smallSpeedHeight = 112.0;

  /// Smallest room for a notice card on one row (icon beside the text).
  static const minNoticeHeight = 76.0;

  /// Room kept above the bottom buttons (48 px buttons up to 22 px above
  /// the inset, plus a gap).
  static const buttonsClear = 22.0 + 48 + gap;

  /// Left edge the signal row keeps clear of on wide screens: a 3-digit
  /// speed in the large type with the unit and gear column (further right
  /// when [speedRowRight] says the row is wider, e.g. large text).
  static const largeSpeedClear = 264.0;

  /// Right edge the signal row keeps clear of: the limit sign.
  static const limitClear = margin + 64 + gap;

  /// Left edge of the signal row on a landscape phone: right of a 3-digit
  /// speed in the small type with the unit and gear column.
  static const shortSpeedClear = 200.0;

  /// Narrowest signal row: both blinkers and room for the light between.
  static const minSignalWidth = 2 * SignalPill.height + 12 + 96.0;

  bool get small => compact || short;

  double get signalTop =>
      short ? 16 : (compact ? (showNumbers ? 146 : 16) : 16);

  /// The blinker row: same place and size with or without a traffic
  /// light.
  Rect get signalRow {
    final speedClear = speedRowRight + gap;
    final left = short && showNumbers
        ? math.max(shortSpeedClear, speedClear)
        : 0.0;
    final right = size.width - (short && showNumbers ? 100.0 : 0.0);
    var width = math.min(SignalPill.width, math.max(0.0, right - left));
    var x = (left + right - width) / 2;
    if (showNumbers && !small) {
      // Same row as the large speed and the limit sign: centered when it
      // clears both, else nudged right of the speed; with large text on a
      // narrow screen it narrows to fit between them.
      final clear = math.max(largeSpeedClear, speedClear);
      final room = size.width - limitClear - clear;
      if (room >= width) {
        x = x.clamp(clear, size.width - limitClear - width);
      } else if (room >= minSignalWidth) {
        width = room;
        x = clear;
      }
    }
    return Rect.fromLTWH(x, signalTop, width, SignalPill.height);
  }

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
  /// calibration): clear of the speed, the signal row, the limit sign, the
  /// bottom buttons and [navOverlayZone], plus where in it the notice sits.
  NoticeArea get noticeArea {
    final bottom = size.height - bottomInset - buttonsClear;
    final zone = navOverlayZone;
    final belowTop =
        math.max(
          signalRow.bottom,
          showNumbers && short ? speedTop + smallSpeedHeight : 0.0,
        ) +
        gap;
    if (short) {
      // Under the speed and the signal row, left of the overlay zone.
      return (
        area: _rect(margin, belowTop, zone.left - gap, bottom),
        alignment: Alignment.center,
      );
    }
    // Under the overlay zone, above the bottom buttons.
    final under = math.max(zone.bottom, signalRow.bottom) + gap;
    if (bottom - under >= minNoticeHeight) {
      return (
        area: _rect(margin, under, size.width - margin, bottom),
        alignment: Alignment.center,
      );
    }
    // Low screens: left of the overlay zone, under the signal row.
    return (
      area: _rect(margin, belowTop, zone.left - gap, bottom),
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

  /// Space between the speed number and the unit / gear column.
  static const unitGap = 10.0;

  static final _speedHalo = _halo(2.2);
  static final _unitHalo = _halo(1.5);

  /// The speed digits. Tabular figures give every digit the same width.
  static TextStyle numberStyle({required bool compact}) => TextStyle(
    fontSize: compact ? 64 : 82,
    height: 0.92,
    fontWeight: FontWeight.w600,
    letterSpacing: -3,
    color: HudColors.ink,
    fontFeatures: const [FontFeature.tabularFigures()],
    shadows: _speedHalo,
  );

  static TextStyle get unitStyle => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: HudColors.unit,
    shadows: _unitHalo,
  );

  static const _threeDigits = [
    '000',
    '111',
    '222',
    '333',
    '444',
    '555',
    '666',
    '777',
    '888',
    '999',
  ];

  /// Width of the box the speed number sits in: the widest three digits in
  /// this font, size and text scale. Any speed from 0 to 999 takes the same
  /// room, so the unit, the gear and the parts beside the cluster stay put
  /// as the speed changes.
  static double numberWidth(BuildContext context, {required bool compact}) =>
      HudText.widest(context, numberStyle(compact: compact), _threeDigits);

  /// Width of the number row (number, unit and gear): the same for every
  /// speed.
  static double rowWidth(
    BuildContext context, {
    required bool compact,
    required SpeedUnit unit,
  }) =>
      numberWidth(context, compact: compact) +
      unitGap +
      math.max(
        HudText.widest(context, unitStyle, [unit.label]),
        GearRow.width(context),
      );

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
              // Right-aligned like a speedometer: the ones digit stays put
              // and the number keeps hugging its unit, as before.
              SizedBox(
                key: const ValueKey('speed-number'),
                width: numberWidth(context, compact: compact),
                child: Text(
                  '$speed',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: numberStyle(compact: compact),
                ),
              ),
              const SizedBox(width: unitGap),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(unit.label, style: unitStyle),
                    const SizedBox(height: 5),
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

/// P R N D on a dark capsule, the current gear white and larger, so it
/// reads on a bright sky, a white building or snow as well as at night.
/// Every letter has a fixed slot: the capsule keeps its size whichever
/// gear is in.
class GearRow extends StatelessWidget {
  const GearRow({required this.gear, super.key});

  final VehicleGear gear;

  static const _gears = [
    (VehicleGear.park, 'P'),
    (VehicleGear.reverse, 'R'),
    (VehicleGear.neutral, 'N'),
    (VehicleGear.drive, 'D'),
  ];

  static const onStyle = TextStyle(
    fontSize: 18,
    height: 1.1,
    fontWeight: FontWeight.w900,
    color: HudColors.gearOn,
  );
  static const offStyle = TextStyle(
    fontSize: 13,
    height: 1.1,
    fontWeight: FontWeight.w700,
    color: HudColors.gearOff,
  );

  /// Every letter on the current gear's line: one baseline, one height.
  static const _strut = StrutStyle(
    fontSize: 18,
    height: 1.1,
    forceStrutHeight: true,
  );

  static const _padding = EdgeInsets.symmetric(horizontal: 5, vertical: 2);
  static const _slotPadding = 3.0;

  static double _slotWidth(BuildContext context) =>
      HudText.widest(context, onStyle, const ['P', 'R', 'N', 'D']) +
      2 * _slotPadding;

  /// Width of the capsule here (font, text scale).
  static double width(BuildContext context) =>
      _gears.length * _slotWidth(context) + _padding.horizontal;

  @override
  Widget build(BuildContext context) {
    final slot = _slotWidth(context);
    return DecoratedBox(
      key: const ValueKey('gear-plate'),
      decoration: BoxDecoration(
        color: HudColors.gearPlate,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: HudColors.gearPlateEdge),
      ),
      child: Padding(
        padding: _padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, label) in _gears)
              SizedBox(
                width: slot,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  strutStyle: _strut,
                  style: value == gear ? onStyle : offStyle,
                ),
              ),
          ],
        ),
      ),
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
