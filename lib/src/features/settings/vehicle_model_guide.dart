import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Offline instructions. No picker, network or vehicle selection changes.
class VehicleModelGuideScreen extends StatelessWidget {
  const VehicleModelGuideScreen({super.key});
  static const manifestExample = '''{
  "schemaVersion": 1,
  "id": "my-car",
  "displayName": "내 자동차",
  "author": "제작자 이름",
  "license": "CC0-1.0",
  "asset": "vehicle.glb",
  "coordinateSystem": "RH_Y_UP_Z_FORWARD",
  "origin": "rearAxleGround",
  "scale": 1.0,
  "dimensionsMeters": {
    "length": 4.9, "width": 1.95,
    "height": 1.7, "wheelbase": 2.9
  }
}''';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('모델 파일 만드는 방법')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            key: const ValueKey('model-guide-scroll'),
            padding: const EdgeInsets.all(20),
            children: [
              const _Section(
                '.kovamodel은 ZIP 패키지예요',
                '자동차 3D 모델(GLB), 설정(JSON), 라이선스를 묶은 파일이에요. GLB·FBX·OBJ의 확장자만 바꾸면 안 돼요. 사진에서 3D 모델을 자동 생성하는 기능은 아니에요.',
              ),
              const _Section(
                '1. Blender에서 GLB로 내보내기',
                '직접 만든 모델이나 사용 허가를 받은 모델을 glTF Binary (.glb)로 내보내고 vehicle.glb로 저장하세요. +Y Up을 켜고 Draco·meshopt 압축은 끄세요. 텍스처는 GLB 안에 포함해야 해요. 외부 파일·URL은 사용할 수 없어요. PNG/JPEG는 이미지당 2048 × 2048 이하, 최대 16장이에요.',
              ),
              const _Section(
                '크기와 방향',
                '미터 단위로 만들고 기준점은 뒷바퀴 축 중앙의 바닥에 두세요. GLB: 위 +Y / 앞 +Z / 차량 왼쪽 +X. Blender: 위 +Z / 앞 −Y / 차량 왼쪽 +X. 삼각형 2만 개 이하를 권장하며 20만 개를 넘으면 가져올 수 없어요.',
              ),
              const _Section(
                '2. 파일 준비하기',
                '필수: vehicle.glb, vehicle.json, LICENSE.md. 선택: README.md, preview.png (1MB 이하, 가로·세로 1024px 이하). 다른 파일이나 하위 폴더는 넣지 마세요. GLB는 하나만 넣어요. LICENSE 또는 LICENSE.txt도 가능해요.',
              ),
              const _Section(
                '3. vehicle.json 작성하기',
                '아래 예시를 UTF-8 파일로 저장하고 차명·제작자·라이선스·실제 치수를 바꾸세요. 치수는 미터이며 폭은 미러를 제외해요. id는 소문자·숫자·하이픈 2–48자예요. 같은 id로 다시 가져오면 기존 모델이 교체돼요. 길이 2.5–7.5m, 폭 1.2–2.8m, 높이 0.9–3.5m, 축거는 1.5m 이상이며 길이보다 최소 0.3m 짧아야 해요.',
              ),
              const _Section(
                '라이선스 확인',
                'CC0-1.0은 예시일 뿐이에요. 원본 모델의 실제 이용 조건을 따르고 LICENSE.md에 제작자·출처·조건을 적어 주세요. 이름만 바꾼다고 이용 권한이 생기지는 않아요.',
              ),
              const SelectableText(manifestExample),
              TextButton.icon(
                key: const ValueKey('model-guide-copy-json'),
                icon: const Icon(Icons.copy),
                label: const Text('vehicle.json 예시 복사'),
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(text: manifestExample),
                  );
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('예시를 복사했어요. 차량 정보와 라이선스를 수정해 주세요.'),
                    ),
                  );
                },
              ),
              const _Section(
                '4. ZIP 압축 후 확장자 바꾸기',
                '폴더 자체가 아니라 안의 파일들을 선택해 ZIP으로 압축하세요. ZIP을 열면 vehicle.json 등이 바로 보여야 해요. my-car.zip을 my-car.kovamodel로 바꾸세요. 확장자 표시를 켜고 .kovamodel.zip이 되지 않았는지 확인하세요. 암호·ZIP64는 지원하지 않아요. 압축 파일과 전체 압축 해제 크기는 각각 32MB 이하, 개별 파일은 24MB 이하예요.',
              ),
              const _Section(
                '5. 앱으로 가져오기',
                '뒤로 돌아가 모델 파일 가져오기를 누르고 .kovamodel 파일을 선택하세요. 오류가 나오면 표시된 이유에 따라 수정해 주세요.',
              ),
              const _Section(
                '색상과 등화 연동 (선택)',
                '부품·재질을 구분해야 색상과 등화 효과를 연결할 수 있어요. 도장 KL_BodyPaint / 유리 KL_Glass / 브레이크등 KL_Brake / 좌·우 방향지시등 KL_TurnLeft·KL_TurnRight. 바퀴 노드 Wheel_FL·Wheel_FR·Wheel_RL·Wheel_RR. 사용자 지정 이름은 JSON의 nodes·materials에 연결해요.',
              ),
              const _Section(
                '개발 도구와 상세 규격',
                'KovaLink 소스와 Dart 환경이 있으면 저장소 루트에서 실행하세요. pack은 생성 후 검사도 해요. 상세 규격: docs/VEHICLE_MODEL_PACK.md, docs/VEHICLE_MODELING_GUIDE.md.',
              ),
              const SelectableText(
                'dart run tool/kovamodel.dart pack my_pack my-car.kovamodel',
              ),
              const SelectableText(
                'dart run tool/kovamodel.dart check my-car.kovamodel',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.text);
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(text),
      ],
    ),
  );
}
