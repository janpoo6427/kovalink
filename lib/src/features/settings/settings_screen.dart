import 'package:flutter/material.dart';
import 'package:kovalink/src/services/gateway_controller.dart';
import 'package:kovalink/src/widgets/page_header.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.controller, super.key});

  final GatewayController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          const PageHeader(
            title: '차량 설정',
            subtitle: 'typed capability와 allowlist에 등록된 항목만 변경합니다.',
          ),
          const SizedBox(height: 22),
          if (!controller.canEditSettings)
            const Card(
              color: Color(0xFF17202A),
              child: ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text(
                  '설정 변경 잠김',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('인증된 gateway 연결 후 안전한 설정만 활성화됩니다.'),
              ),
            ),
          _SettingSection(
            title: '주행 화면',
            enabled: controller.canEditSettings,
            items: const [
              _SettingItem(
                '기본 로드뷰',
                '3D semantic scene',
                Icons.view_in_ar_outlined,
              ),
              _SettingItem('Telemetry rate', '10 Hz', Icons.speed_outlined),
              _SettingItem('카메라 자동 시작', '사용 안 함', Icons.videocam_off_outlined),
            ],
          ),
          const _SettingSection(
            title: '개인정보',
            enabled: false,
            items: [
              _SettingItem(
                'Comma Connect',
                '소스 정책으로 비활성화',
                Icons.cloud_off_outlined,
              ),
              _SettingItem(
                'Route upload',
                '소스 정책으로 비활성화',
                Icons.upload_file_outlined,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Text(
              'Safety parameter, cloud privacy policy, 차량 actuation은 앱에서 변경할 수 없습니다.',
              style: TextStyle(color: Color(0xFF8E9DA9), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingSection extends StatelessWidget {
  const _SettingSection({
    required this.title,
    required this.enabled,
    required this.items,
  });
  final String title;
  final bool enabled;
  final List<_SettingItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF8E9DA9),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(
            child: Column(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  ListTile(
                    enabled: enabled,
                    leading: Icon(items[index].icon),
                    title: Text(items[index].label),
                    subtitle: Text(items[index].value),
                    trailing: const Icon(Icons.chevron_right),
                  ),
                  if (index != items.length - 1)
                    const Divider(height: 1, indent: 56),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingItem {
  const _SettingItem(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}
