import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Offline instructions only: never starts installation or contacts a device.
class InstallGuidePanel extends StatelessWidget {
  const InstallGuidePanel({super.key});

  static const installAddress = 'installer.comma.ai/janpoo6427/kovapilot';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      Text('KovaPilot 설치하기', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text(
        '콤마의 설치 화면에서 아래 주소를 입력하세요.\n'
        'KovaLink는 설치 방법만 안내하며 기기를 변경하지 않습니다.',
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('설치 주소', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const SelectableText(
                installAddress,
                key: ValueKey('install-address'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey('copy-install-address'),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('주소 복사'),
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: installAddress),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('설치 주소를 복사했어요')));
                },
              ),
              const SizedBox(height: 8),
              const Text(
                '휴대폰 브라우저가 아니라 콤마의 사용자 지정 '
                '소프트웨어 주소 입력란에 입력하세요. ZIP 업로드는 필요 없습니다.',
              ),
            ],
          ),
        ),
      ),
      const _GuideCard(
        title: '설치 전 준비',
        icon: Icons.checklist_outlined,
        body:
            '• 안전한 곳에 주차하고 주행 중에는 설치하지 마세요.\n'
            '• 안정적인 Wi-Fi와 전원을 준비하세요. 완료 전 전원을 끄지 마세요.\n'
            '• 설치 전 여유 공간이 최소 12 GiB 필요합니다. 빌드에는 더 필요할 수 있어요.\n'
            '• 차량과 콤마 모델의 지원 여부를 먼저 확인하세요.',
      ),
      const _GuideCard(
        title: '처음 설치하는 콤마',
        icon: Icons.add_to_queue_outlined,
        body:
            '1. 콤마 초기 설정에서 Wi-Fi를 연결합니다.\n'
            '2. 사용자 지정 소프트웨어 설치를 선택합니다. '
            '화면의 명칭은 기기 버전에 따라 다를 수 있어요.\n'
            '3. 위 설치 주소를 입력하고 화면 안내를 따릅니다.\n'
            '4. 본체와 모델 다운로드, 검증, 초기 빌드가 끝날 때까지 기다립니다.',
      ),
      const _GuideCard(
        title: '기존 포크에서 전환 · 재설치',
        icon: Icons.swap_horiz,
        body:
            '1. 중요한 설정과 필요한 주행 기록을 먼저 별도로 백업하세요.\n'
            '2. 현재 포크가 제공하는 공식 제거·소프트웨어 변경 절차로 '
            '설치 화면에 진입하세요. 삭제되는 데이터와 확인 문구를 읽고 진행하세요.\n'
            '3. 위 주소를 입력하고 설치를 진행합니다.\n'
            '기존 설정이 모두 유지된다고 보장하지 않습니다. '
            '공장 초기화를 필수 단계로 권장하지 않으며, '
            'KovaLink의 브랜치 변경 기능만으로 다른 포크에서 전환하지 마세요.',
      ),
      const _GuideCard(
        title: '설치 후 확인',
        icon: Icons.fact_check_outlined,
        body:
            '• 정상 화면 진입과 설치 버전, 차량 설정을 확인하세요.\n'
            '• 보정 안내와 장치 경고를 확인하고 문제가 있으면 주행에 사용하지 마세요.\n'
            '• 정상 부팅 후 KovaLink의 연결 상태에서 장치를 연결하세요.\n'
            '안내 페이지와 주소 확인만으로 실제 기기의 정상 부팅이나 '
            '주행 안전성이 검증되는 것은 아닙니다.',
      ),
      const _GuideCard(
        title: '설치가 중단되면',
        icon: Icons.help_outline,
        body:
            '화면의 오류를 기록하고 네트워크·전원·여유 공간을 확인하세요. '
            '같은 오류가 반복되면 중단 단계와 오류 내용을 공유하세요. '
            '검증을 건너뛰거나 백업을 임의로 삭제하지 마세요.\n'
            '부트스트랩 로그: /data/kovapilot-bootstrap/install.log\n'
            '이 로그는 설치 스크립트에 진입한 이후에 생성됩니다.',
      ),
    ],
  );
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.title,
    required this.icon,
    required this.body,
  });
  final String title;
  final IconData icon;
  final String body;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.6)),
        ],
      ),
    ),
  );
}
