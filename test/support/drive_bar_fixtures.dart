// Fixtures for the drive screen's bottom bar: an 자동 연결 controller held
// in one state with the wording the real controller shows in it, every
// such wording, and the phone from the 2026-11-25 16:39 screenshot.
import 'package:flutter/widgets.dart';
import 'package:kovalink/src/services/auto_connect_controller.dart';

import 'device_profiles.dart';
import 'fake_auto_connect.dart';

/// One chip state: phase, the exact wording [AutoConnectController]
/// shows in it, and whether a comma refused phones (local only).
typedef ChipState = ({AutoConnectPhase phase, String label, bool localOnly});

ChipState _s(AutoConnectPhase phase, String label, {bool localOnly = false}) =>
    (phase: phase, label: label, localOnly: localOnly);

/// Every chip wording, with small and large numbers. The wordings are
/// checked against the real controller in drive_bottom_bar_test.dart.
final chipStates = <ChipState>[
  _s(AutoConnectPhase.off, '자동 연결 꺼짐'),
  _s(AutoConnectPhase.paused, '자동 연결 멈춤'),
  _s(AutoConnectPhase.searching, '콤마 찾는 중 · 1번째'),
  _s(AutoConnectPhase.searching, '콤마 찾는 중 · 240번째'),
  _s(AutoConnectPhase.waiting, '콤마 없음 · 2초 뒤 다시'),
  _s(AutoConnectPhase.waiting, '콤마 없음 · 15초 뒤 다시'),
  _s(AutoConnectPhase.waiting, '콤마 찾음 · 휴대폰 연결 아직 허용 안 됨', localOnly: true),
  _s(AutoConnectPhase.choosing, '콤마 2대 찾음'),
  _s(AutoConnectPhase.choosing, '콤마 12대 찾음'),
  _s(AutoConnectPhase.connected, '콤마 연결됨'),
];

/// The longest wording (the one that needs the most room).
ChipState get longestChipState => chipStates.firstWhere((s) => s.localOnly);

/// An [AutoConnectController] that never searches and shows [state].
class FixedAutoConnect extends AutoConnectController {
  FixedAutoConnect([ChipState? state])
    : state = state ?? chipStates.first,
      super(
        target: FakeTarget(),
        probe: FakeProbe(),
        listNetworks: () async => const [],
      );

  ChipState state;

  @override
  AutoConnectPhase get phase => state.phase;

  @override
  String get statusLabel => state.label;

  @override
  List<String> get localOnly =>
      state.localOnly ? const ['192.168.0.40'] : const [];

  void show(ChipState next) {
    state = next;
    notifyListeners();
  }
}

/// The phone in janpoo's 2026-11-25 16:39 screenshot (1440×2936 px):
/// the round buttons measure 180 px = 48 dp there, so 3.75 px per dp,
/// 384×783 dp; the app area had no insets.
const reportedPhone = DeviceProfile(
  id: 'phone_384x783',
  label: '16:39 실기기 사진 크기',
  width: 384,
  height: 783,
  dpr: 3.75,
  group: DeviceGroup.phone,
  padding: EdgeInsets.zero,
);
