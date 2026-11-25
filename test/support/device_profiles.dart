// Representative device sizes for layout checks and review captures.
//
// Sizes are logical (dp) with the device pixel ratio; [padding] is the
// system inset (status bar, notch/cutout, home indicator) in dp, the same
// values MediaQuery.padding reports on those devices.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

enum DeviceGroup { phone, foldable, tablet }

class DeviceProfile {
  const DeviceProfile({
    required this.id,
    required this.label,
    required this.width,
    required this.height,
    required this.dpr,
    required this.group,
    this.padding = EdgeInsets.zero,
  });

  /// File-name safe id, e.g. `phone_393x852`.
  final String id;

  /// Human label for sheets, e.g. `iPhone 15 (393×852 @3)`.
  final String label;
  final double width;
  final double height;
  final double dpr;
  final DeviceGroup group;
  final EdgeInsets padding;

  bool get landscape => width > height;
  Size get logical => Size(width, height);
  Size get physical => Size(width * dpr, height * dpr);
  String get sizeLabel =>
      '${_n(width)}×${_n(height)} dp @${_n(dpr)} '
      '(${physical.width.round()}×${physical.height.round()} px)';

  /// Same device turned sideways; the insets move with the hardware.
  DeviceProfile rotated({required EdgeInsets padding}) => DeviceProfile(
    id: '${id.split('_').first}_${_n(height)}x${_n(width)}',
    label: label,
    width: height,
    height: width,
    dpr: dpr,
    group: group,
    padding: padding,
  );

  /// Applies this device to the test view; undo with `tester.view.reset()`.
  void apply(WidgetTester tester) {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    final inset = FakeViewPadding(
      left: padding.left * dpr,
      top: padding.top * dpr,
      right: padding.right * dpr,
      bottom: padding.bottom * dpr,
    );
    tester.view.padding = inset;
    tester.view.viewPadding = inset;
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

const _small = DeviceProfile(
  id: 'phone_360x640',
  label: '작은 폰 (Galaxy A 계열)',
  width: 360,
  height: 640,
  dpr: 2,
  group: DeviceGroup.phone,
  padding: EdgeInsets.only(top: 24),
);
const _se = DeviceProfile(
  id: 'phone_375x667',
  label: 'iPhone SE',
  width: 375,
  height: 667,
  dpr: 2,
  group: DeviceGroup.phone,
  padding: EdgeInsets.only(top: 20),
);
const _iphone = DeviceProfile(
  id: 'phone_393x852',
  label: 'iPhone 15',
  width: 393,
  height: 852,
  dpr: 3,
  group: DeviceGroup.phone,
  padding: EdgeInsets.only(top: 59, bottom: 34),
);
const _galaxy = DeviceProfile(
  id: 'phone_412x915',
  label: 'Galaxy S / Pixel',
  width: 412,
  height: 915,
  dpr: 2.625,
  group: DeviceGroup.phone,
  padding: EdgeInsets.only(top: 32, bottom: 24),
);
const _fold = DeviceProfile(
  id: 'fold_690x829',
  label: 'Galaxy Z Fold 펼침',
  width: 690,
  height: 829,
  dpr: 2.625,
  group: DeviceGroup.foldable,
  padding: EdgeInsets.only(top: 26, bottom: 24),
);
const _foldCover = DeviceProfile(
  id: 'fold_344x882',
  label: 'Galaxy Z Fold 접힘 (바깥 화면)',
  width: 344,
  height: 882,
  dpr: 2.625,
  group: DeviceGroup.foldable,
  padding: EdgeInsets.only(top: 26, bottom: 24),
);
const _tab7 = DeviceProfile(
  id: 'tablet_600x960',
  label: '7인치 태블릿 (Galaxy Tab A 7)',
  width: 600,
  height: 960,
  dpr: 2,
  group: DeviceGroup.tablet,
  padding: EdgeInsets.only(top: 24, bottom: 24),
);
const _ipadMini = DeviceProfile(
  id: 'tablet_744x1133',
  label: 'iPad mini',
  width: 744,
  height: 1133,
  dpr: 2,
  group: DeviceGroup.tablet,
  padding: EdgeInsets.only(top: 24, bottom: 20),
);
const _tab10 = DeviceProfile(
  id: 'tablet_800x1280',
  label: '10인치 태블릿 (Galaxy Tab)',
  width: 800,
  height: 1280,
  dpr: 2,
  group: DeviceGroup.tablet,
  padding: EdgeInsets.only(top: 24, bottom: 24),
);
const _ipad11 = DeviceProfile(
  id: 'tablet_834x1194',
  label: 'iPad Pro 11',
  width: 834,
  height: 1194,
  dpr: 2,
  group: DeviceGroup.tablet,
  padding: EdgeInsets.only(top: 24, bottom: 20),
);
const _ipad13 = DeviceProfile(
  id: 'tablet_1024x1366',
  label: 'iPad Pro 12.9',
  width: 1024,
  height: 1366,
  dpr: 2,
  group: DeviceGroup.tablet,
  padding: EdgeInsets.only(top: 24, bottom: 20),
);

/// Portrait devices, smallest first.
const portraitDevices = <DeviceProfile>[
  _small,
  _se,
  _iphone,
  _galaxy,
  _foldCover,
  _fold,
  _tab7,
  _ipadMini,
  _tab10,
  _ipad11,
  _ipad13,
];

/// Landscape devices (phones on a car mount, tablets on a stand).
final landscapeDevices = <DeviceProfile>[
  _small.rotated(padding: const EdgeInsets.only(top: 24)),
  // iPhone: notch on one side, home indicator at the bottom.
  _iphone.rotated(padding: const EdgeInsets.fromLTRB(59, 0, 59, 21)),
  // Android car mount: status bar on top, camera cutout on the left.
  _galaxy.rotated(padding: const EdgeInsets.fromLTRB(32, 24, 0, 24)),
  // Fold cover screen on a mount: very short and wide.
  _foldCover.rotated(padding: const EdgeInsets.fromLTRB(26, 24, 0, 24)),
  _fold.rotated(padding: const EdgeInsets.only(top: 26, bottom: 24)),
  _tab7.rotated(padding: const EdgeInsets.only(top: 24, bottom: 24)),
  _tab10.rotated(padding: const EdgeInsets.only(top: 24, bottom: 24)),
  _ipad11.rotated(padding: const EdgeInsets.only(top: 24, bottom: 20)),
  _ipad13.rotated(padding: const EdgeInsets.only(top: 24, bottom: 20)),
];

List<DeviceProfile> get allDevices => [...portraitDevices, ...landscapeDevices];
