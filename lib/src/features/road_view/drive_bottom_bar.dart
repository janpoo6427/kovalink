import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:kovalink/src/features/road_view/hud/drive_hud.dart';

/// The drive screen's bottom row: the view mode button on the left (drawn
/// by the road view) and, on the right, the round buttons with the 자동
/// 연결 chip beside them (drawn by the home screen).
///
/// The chip sits between the mode button and the round buttons only when
/// its longest wording fits there; otherwise it gets a row of its own
/// above the round buttons. That depends only on the screen width and the
/// text size, never on what the chip says right now, so the chip does not
/// change rows as the connection state changes, and the road view keeps
/// its notices clear of the rows in use ([DriveBarLayout.noticeRise]).
abstract final class DriveBar {
  /// Side margin, the same as the HUD's.
  static const margin = HudLayout.margin;

  /// Gap between the button row and the bottom inset (home indicator,
  /// navigation bar).
  static const bottom = 18.0;

  /// Round buttons and the chip's height: the 48 dp touch target.
  static const button = 48.0;

  /// Between the round buttons, and between the chip and them.
  static const gap = 10.0;

  /// Between the chip's own row and the button row.
  static const rowGap = 8.0;

  /// Left part of the button row kept for the view mode button.
  static const modeClear = margin + button + gap;

  /// Height above the bottom inset the road view keeps for a bar of one
  /// row ([HudLayout.buttonsClear] without its gap).
  static const oneRowClear = HudLayout.buttonsClear - HudLayout.gap;
}

/// Where the parts of [DriveBar] go on a screen [width] dp wide (inside
/// the side insets) with [buttons] round buttons on the right.
class DriveBarLayout {
  /// [chip] is the size the chip needs for its longest wording at the
  /// current text size; null when there is no chip.
  factory DriveBarLayout({
    required double width,
    required int buttons,
    Size? chip,
  }) {
    final buttonsWidth = buttons <= 0
        ? 0.0
        : buttons * DriveBar.button + (buttons - 1) * DriveBar.gap;
    final slot = math.max(
      0.0,
      width -
          DriveBar.modeClear -
          DriveBar.margin -
          buttonsWidth -
          DriveBar.gap,
    );
    final inline = chip != null && chip.width <= slot;
    return DriveBarLayout._(
      hasChip: chip != null,
      chipInline: inline,
      chipMaxWidth: chip == null
          ? 0
          : inline
          ? slot
          : math.max(0.0, width - 2 * DriveBar.margin),
      chipHeight: chip == null ? 0 : math.max(DriveBar.button, chip.height),
    );
  }

  const DriveBarLayout._({
    required this.hasChip,
    required this.chipInline,
    required this.chipMaxWidth,
    required this.chipHeight,
  });

  final bool hasChip;

  /// The chip shares the button row (left of the round buttons); false:
  /// it has a row of its own above them.
  final bool chipInline;

  /// Widest the chip may be where it sits; longer wordings are cut with
  /// an ellipsis (only past the text sizes the layout is checked for).
  final double chipMaxWidth;

  /// The chip's height (48 dp unless the text is very large).
  final double chipHeight;

  /// Bottom of the chip's own row above the bottom inset.
  double get chipRowBottom =>
      DriveBar.bottom + DriveBar.button + DriveBar.rowGap;

  /// Height of the whole bar above the bottom inset.
  double get height => !hasChip
      ? DriveBar.bottom + DriveBar.button
      : chipInline
      ? DriveBar.bottom + math.max(DriveBar.button, chipHeight)
      : chipRowBottom + chipHeight;

  /// How much higher than a one-row bar this bar reaches: the road view
  /// lifts the bottom of its notice room by this much.
  double get noticeRise => math.max(0.0, height - DriveBar.oneRowClear);
}
