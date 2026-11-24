import 'dart:convert';
import 'dart:typed_data';

import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/vehicle_pack/glb_inspector.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

/// Result of validating a `.kovamodel` pack. Either [manifest] is set and
/// [rejection] is null, or the pack was refused with a user-facing reason.
class ModelPackValidation {
  const ModelPackValidation._({
    this.manifest,
    this.files = const {},
    this.glb,
    this.rejection,
    this.warnings = const [],
  });

  final VehicleModelManifest? manifest;
  final Map<String, Uint8List> files;
  final GlbReport? glb;
  final ModelPackRejection? rejection;
  final List<String> warnings;

  bool get accepted => rejection == null;
}

/// Validates user-supplied vehicle model packs before anything is copied
/// into app storage. See docs/VEHICLE_MODEL_PACK.md for the published format.
class ModelPackValidator {
  const ModelPackValidator._();

  static const fileExtension = '.kovamodel';
  static const manifestName = 'vehicle.json';
  static const licenseNames = {'LICENSE', 'LICENSE.md', 'LICENSE.txt'};
  static const optionalNames = {'README.md', 'preview.png'};
  static const maxManifestBytes = 64 * 1024;
  static const maxTextBytes = 256 * 1024;
  static const maxPreviewBytes = 1024 * 1024;
  static const maxPreviewSize = 1024;

  static final RegExp packId = RegExp(r'^[a-z0-9][a-z0-9-]{1,47}$');

  static ModelPackValidation validate(
    Uint8List archive, {
    ZipLimits zipLimits = const ZipLimits(),
    GlbLimits glbLimits = const GlbLimits(),
  }) {
    try {
      final files = SafeZipReader.read(archive, limits: zipLimits);
      return _validateFiles(files, glbLimits);
    } on ModelPackRejection catch (rejection) {
      return ModelPackValidation._(rejection: rejection);
    }
  }

  static ModelPackValidation _validateFiles(
    Map<String, Uint8List> files,
    GlbLimits glbLimits,
  ) {
    final manifestBytes = files[manifestName];
    if (manifestBytes == null) {
      throw const ModelPackRejection('missing-manifest', 'vehicle.json이 없습니다.');
    }
    if (manifestBytes.length > maxManifestBytes) {
      throw const ModelPackRejection(
        'manifest-too-large',
        'vehicle.json이 너무 큽니다(최대 64 KB).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } on FormatException {
      throw const ModelPackRejection(
        'manifest-json',
        'vehicle.json이 올바른 JSON이 아닙니다.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ModelPackRejection(
        'manifest-json',
        'vehicle.json은 JSON object여야 합니다.',
      );
    }
    _requireFields(decoded);

    final VehicleModelManifest manifest;
    try {
      manifest = VehicleModelManifest.fromJson(decoded);
    } on FormatException catch (error) {
      throw ModelPackRejection(
        'manifest-field',
        'vehicle.json 값 오류: ${error.message}',
      );
    } on Object {
      throw const ModelPackRejection(
        'manifest-field',
        'vehicle.json 값의 형식이 올바르지 않습니다.',
      );
    }

    if (!packId.hasMatch(manifest.id)) {
      throw const ModelPackRejection(
        'manifest-id',
        'id는 소문자·숫자·하이픈 2–48자여야 합니다(예: my-ioniq9).',
      );
    }
    if (manifest.displayName.trim().isEmpty ||
        manifest.displayName.length > 48) {
      throw const ModelPackRejection(
        'manifest-name',
        'displayName은 1–48자여야 합니다.',
      );
    }
    if ((manifest.author ?? '').trim().isEmpty ||
        manifest.author!.length > 80) {
      throw const ModelPackRejection(
        'manifest-author',
        'author(작성자)가 필요합니다(최대 80자).',
      );
    }
    if ((manifest.license ?? '').trim().isEmpty ||
        manifest.license!.length > 64) {
      throw const ModelPackRejection(
        'manifest-license',
        'license(SPDX 식별자, 예: CC0-1.0)가 필요합니다.',
      );
    }
    if (manifest.coordinateSystem != 'RH_Y_UP_Z_FORWARD') {
      throw const ModelPackRejection(
        'manifest-axes',
        'coordinateSystem은 RH_Y_UP_Z_FORWARD(+X 오른쪽, +Y 위, +Z 앞)여야 합니다.',
      );
    }
    if (manifest.origin != VehicleModelManifest.defaultOrigin) {
      throw const ModelPackRejection(
        'manifest-origin',
        'origin은 rearAxleGround(뒷차축 가운데 바닥)여야 합니다.',
      );
    }
    if (!manifest.scale.isFinite ||
        manifest.scale < 0.001 ||
        manifest.scale > 1000) {
      throw const ModelPackRejection(
        'manifest-scale',
        'scale은 0.001–1000 범위여야 합니다.',
      );
    }
    final dimensionError = manifest.dimensions.validationError;
    if (dimensionError != null) {
      throw ModelPackRejection('manifest-dimensions', dimensionError);
    }
    if (!VehicleModelManifest.isSafeAssetFileName(manifest.asset)) {
      throw const ModelPackRejection(
        'manifest-asset',
        'asset은 폴더 없는 .glb 파일 이름이어야 합니다(예: vehicle.glb).',
      );
    }
    final appearance = decoded['appearance'];
    if (appearance != null) {
      final colors = appearance is Map<String, dynamic>
          ? [
              appearance['paintColor'],
              appearance['glassColor'],
              appearance['lampColor'],
            ]
          : [appearance];
      if (colors.any(
        (value) =>
            value != null && VehicleAppearance.parseHexColor(value) == null,
      )) {
        throw const ModelPackRejection(
          'manifest-color',
          'appearance 색은 #RRGGBB 형식이어야 합니다.',
        );
      }
    }

    if (!files.keys.any(licenseNames.contains)) {
      throw const ModelPackRejection(
        'missing-license',
        'LICENSE(.md/.txt) 파일이 필요합니다.',
      );
    }
    for (final name in files.keys) {
      final allowed =
          name == manifestName ||
          name == manifest.asset ||
          licenseNames.contains(name) ||
          optionalNames.contains(name);
      if (!allowed) {
        throw ModelPackRejection(
          'unexpected-file',
          '모델 팩에 넣을 수 없는 파일입니다: $name (스크립트·실행 파일·추가 GLB 금지)',
        );
      }
    }
    for (final name in [...licenseNames, 'README.md']) {
      final text = files[name];
      if (text == null) continue;
      if (text.length > maxTextBytes) {
        throw ModelPackRejection('text-too-large', '$name이 너무 큽니다(최대 256 KB).');
      }
      try {
        utf8.decode(text);
      } on FormatException {
        throw ModelPackRejection('text-encoding', '$name은 UTF-8 텍스트여야 합니다.');
      }
    }
    final preview = files['preview.png'];
    if (preview != null) {
      final size = GlbInspector.imageSize(preview);
      if (preview.length > maxPreviewBytes ||
          size == null ||
          preview[1] != 0x50 ||
          size.$1 > maxPreviewSize ||
          size.$2 > maxPreviewSize) {
        throw const ModelPackRejection(
          'preview-invalid',
          'preview.png는 1 MB·1024px 이하 PNG여야 합니다.',
        );
      }
    }

    final glbBytes = files[manifest.asset];
    if (glbBytes == null) {
      throw ModelPackRejection('missing-glb', '${manifest.asset} 파일이 없습니다.');
    }
    final glb = GlbInspector.inspect(glbBytes, limits: glbLimits);

    final warnings = [...glb.warnings];
    final missingNodes = manifest.nodes.all
        .where((name) => !glb.nodeNames.contains(name))
        .toList();
    if (missingNodes.isNotEmpty) {
      warnings.add('GLB에 없는 노드 이름(효과 생략): ${missingNodes.join(', ')}');
    }
    final missingMaterials = manifest.materials.all
        .where((name) => !glb.materialNames.contains(name))
        .toList();
    if (missingMaterials.isNotEmpty) {
      warnings.add('GLB에 없는 머티리얼 이름(효과 생략): ${missingMaterials.join(', ')}');
    }
    return ModelPackValidation._(
      manifest: manifest,
      files: files,
      glb: glb,
      warnings: List.unmodifiable(warnings),
    );
  }

  static void _requireFields(Map<String, dynamic> json) {
    const required = [
      'schemaVersion',
      'id',
      'displayName',
      'author',
      'license',
      'asset',
      'coordinateSystem',
      'dimensionsMeters',
    ];
    final missing = required.where((key) => json[key] == null).toList();
    if (missing.isNotEmpty) {
      throw ModelPackRejection(
        'manifest-missing-field',
        'vehicle.json 필수 항목이 없습니다: ${missing.join(', ')}',
      );
    }
    if (json['schemaVersion'] != 1) {
      throw const ModelPackRejection(
        'manifest-schema',
        '지원하는 schemaVersion은 1입니다.',
      );
    }
  }
}
