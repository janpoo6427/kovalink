import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kovalink/src/features/road_view/hud/nav_cards.dart';
import 'package:kovalink/src/kova_params/kova_params_controller.dart';
import 'package:kovalink/src/kova_params/kova_params_document.dart';
import 'package:kovalink/src/models/road_scene.dart';
import 'package:kovalink/src/services/gateway_controller.dart';

/// Read-only summary. Configured values, runtime states and missing telemetry
/// are distinct; an empty object list never implies radar is disabled.
class VehicleFeaturesCard extends StatefulWidget {
  const VehicleFeaturesCard({
    required this.gateway,
    required this.settings,
    super.key,
  });
  final GatewayController gateway;
  final KovaParamsController settings;

  @override
  State<VehicleFeaturesCard> createState() => _VehicleFeaturesCardState();
}

class _VehicleFeaturesCardState extends State<VehicleFeaturesCard> {
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.gateway, widget.settings]),
    builder: (context, _) {
      final g = widget.gateway;
      final k = widget.settings;
      final at = g.lastTelemetryAt;
      final fresh =
          g.mode == GatewayMode.live &&
          at != null &&
          DateTime.now().difference(at) <= const Duration(seconds: 5);
      final lane = fresh ? g.scene.autoLaneChange : null;
      final doc = k.status == KovaLinkStatus.connected ? k.document : null;
      final states = <String, KovaParamDependency>{};
      if (doc != null) {
        for (final setting in doc.settings.values.where((s) => !s.hidden)) {
          for (final state in setting.runtimeStates) {
            final name = state.title.resolve(defaultLocale: doc.defaultLocale);
            states['${state.condition ?? name}:${state.state}'] = state;
          }
        }
      }
      final accent = Theme.of(context).colorScheme.primary;
      return Card(
        key: const ValueKey('vehicle-features-card'),
        margin: const EdgeInsets.symmetric(vertical: 12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.auto_awesome_outlined, color: accent),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '이 차량의 운행 기능',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text('설정과 실제 동작을 한눈에', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                fresh
                    ? '최근 수신한 차량 정보 · 읽기 전용'
                    : g.mode == GatewayMode.demo
                    ? '데모 화면 · 실제 차량 적용 상태는 확인할 수 없어요'
                    : '차량 정보 수신 대기 · 이전 값을 현재 상태로 표시하지 않아요',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _FeatureTile(
                icon: Icons.alt_route,
                title: '자동 차선 변경',
                label: switch (lane?.setting) {
                  AutoLaneChangeSetting.on => '설정 켬',
                  AutoLaneChangeSetting.off => '설정 끔',
                  _ => '확인할 수 없음',
                },
                highlighted: lane?.setting == AutoLaneChangeSetting.on,
                detail: lane == null
                    ? '차량의 설정·동작 정보를 받으면 표시합니다.'
                    : '현재 동작 · ${laneChangeStateText(lane)}\n설정이 켜져 있어도 항상 차선을 변경하는 것은 아닙니다.',
              ),
              _FeatureTile(
                icon: Icons.visibility_outlined,
                title: '사각지대 감지 · BSM',
                label: switch (lane?.blindSpotFresh) {
                  true => '신호 수신',
                  false => '신호 오래됨',
                  _ => '확인할 수 없음',
                },
                highlighted: lane?.blindSpotFresh == true,
                detail: lane?.blindSpotFresh == true
                    ? '왼쪽 ${_blind(lane?.blindSpotLeft)} · 오른쪽 ${_blind(lane?.blindSpotRight)}\n좌우 경고 신호이며 물체 위치 정보는 아닙니다.'
                    : '신호가 확인되지 않으면 미지원·경고 없음으로 판단하지 않습니다.',
              ),
              const _FeatureTile(
                icon: Icons.radar,
                title: '레이더 트랙',
                label: '확인할 수 없음',
                detail:
                    '현재 게이트웨이는 차량별 적용 여부와 레이더 물체 좌표를 보내지 않습니다.\n물체가 0개인 것과 기능이 꺼진 것은 다릅니다.',
              ),
              for (final state in states.values)
                _FeatureTile(
                  icon: Icons.settings_input_component_outlined,
                  title: state.title.resolve(defaultLocale: doc?.defaultLocale),
                  label: runtimeFeatureLabel(state.state),
                  highlighted: state.state == 'active',
                  detail: '차량이 보고한 현재 적용 상태',
                ),
              if (states.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '추가 운행 기능은 차량이 적용 상태를 보고하면 여기에 모아 표시합니다. '
                    '저장된 설정값만으로 사용 중이라고 판단하지 않습니다.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _blind(bool? value) => switch (value) {
  true => '감지',
  false => '경고 없음',
  null => '미확인',
};
String runtimeFeatureLabel(String value) => switch (value) {
  'active' => '사용 중',
  'off' => '꺼짐',
  'waiting' => '대기',
  'awaitingAuthority' => '제어 권한 대기',
  'paused' => '일시중지',
  'manualRequired' => '수동 재개 필요',
  'unsupported' => '이 차량에서 미지원',
  _ => '확인할 수 없음',
};

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.label,
    required this.detail,
    this.highlighted = false,
  });
  final IconData icon;
  final String title, label, detail;
  final bool highlighted;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = highlighted ? colors.primary : colors.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withValues(alpha: .14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 21, color: tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: tint,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            detail,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
