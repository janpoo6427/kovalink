import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kovalink/src/vehicle_pack/glb_inspector.dart';
import 'package:kovalink/src/vehicle_pack/model_pack_validator.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';
import 'package:kovalink/src/vehicle_pack/zip_writer.dart';

/// Minimal valid GLB: one triangle mesh plus optional PNG texture.
Uint8List buildGlb({
  List<String> nodeNames = const ['Body'],
  List<String> materialNames = const ['KL_BodyPaint'],
  Map<String, dynamic>? buffer,
  Map<String, dynamic>? image,
  int triangleIndices = 3,
  List<String>? extensionsRequired,
  (int, int)? pngSize,
  int magic = 0x46546C67,
}) {
  final bin = BytesBuilder();
  bin.add(Uint8List(36)); // 3 vertices * VEC3 float
  final views = <Map<String, dynamic>>[
    {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
  ];
  final images = <Map<String, dynamic>>[];
  if (pngSize != null) {
    final png = ByteData(24)
      ..setUint32(0, 0x89504E47)
      ..setUint32(4, 0x0D0A1A0A)
      ..setUint32(12, 0x49484452)
      ..setUint32(16, pngSize.$1)
      ..setUint32(20, pngSize.$2);
    views.add({'buffer': 0, 'byteOffset': 36, 'byteLength': 24});
    bin.add(png.buffer.asUint8List());
    images.add({'bufferView': 1, 'mimeType': 'image/png'});
  }
  if (image != null) images.add(image);
  final binBytes = bin.takeBytes();
  final gltf = {
    'asset': {'version': '2.0'},
    'extensionsRequired': ?extensionsRequired,
    'nodes': [
      for (final (index, name) in nodeNames.indexed)
        {'name': name, if (index == 0) 'mesh': 0},
    ],
    'materials': [
      for (final name in materialNames) {'name': name},
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'indices': 1,
          },
        ],
      },
    ],
    'accessors': [
      {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
      {
        'bufferView': 0,
        'componentType': 5123,
        'count': triangleIndices,
        'type': 'SCALAR',
      },
    ],
    'bufferViews': views,
    'buffers': [
      buffer ?? {'byteLength': binBytes.length},
    ],
    'images': images,
  };
  var json = utf8.encode(jsonEncode(gltf));
  json = Uint8List.fromList([
    ...json,
    ...List.filled((4 - json.length % 4) % 4, 0x20),
  ]);
  final total = 12 + 8 + json.length + 8 + binBytes.length;
  final out = ByteData(20);
  out
    ..setUint32(0, magic, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, total, Endian.little)
    ..setUint32(12, json.length, Endian.little)
    ..setUint32(16, 0x4E4F534A, Endian.little);
  final chunk = ByteData(8)
    ..setUint32(0, binBytes.length, Endian.little)
    ..setUint32(4, 0x004E4942, Endian.little);
  return Uint8List.fromList([
    ...out.buffer.asUint8List(),
    ...json,
    ...chunk.buffer.asUint8List(),
    ...binBytes,
  ]);
}

Map<String, dynamic> manifestJson({
  Map<String, dynamic> overrides = const {},
}) => {
  'schemaVersion': 1,
  'id': 'my-test-car',
  'displayName': '내 시험 차',
  'author': 'Test Author',
  'license': 'CC0-1.0',
  'asset': 'vehicle.glb',
  'coordinateSystem': 'RH_Y_UP_Z_FORWARD',
  'origin': 'rearAxleGround',
  'dimensionsMeters': {
    'length': 4.7,
    'width': 1.9,
    'height': 1.6,
    'wheelbase': 2.9,
  },
  'nodes': {'body': 'Body'},
  'materials': {'bodyPaint': 'KL_BodyPaint'},
  ...overrides,
};

Uint8List pack({
  Map<String, dynamic>? manifest,
  Uint8List? glb,
  Map<String, List<int>> extra = const {},
  bool license = true,
}) => ZipWriter.build([
  ZipWriterEntry(
    'vehicle.json',
    utf8.encode(jsonEncode(manifest ?? manifestJson())),
  ),
  ZipWriterEntry('vehicle.glb', glb ?? buildGlb()),
  if (license) ZipWriterEntry('LICENSE.md', utf8.encode('CC0-1.0')),
  for (final MapEntry(:key, :value) in extra.entries)
    ZipWriterEntry(key, value),
]);

String? rejectionCode(
  Uint8List archive, {
  ZipLimits zipLimits = const ZipLimits(),
}) =>
    ModelPackValidator.validate(archive, zipLimits: zipLimits).rejection?.code;

Uint8List packDirectory(String directory) => ZipWriter.build([
  for (final file in Directory(directory).listSync().whereType<File>())
    ZipWriterEntry(file.uri.pathSegments.last, file.readAsBytesSync()),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('published example packs', () {
    test('KovaLink basic pack passes without warnings', () {
      final result = ModelPackValidator.validate(
        packDirectory('assets/vehicles/kovalink_basic'),
      );
      expect(result.rejection, isNull);
      expect(result.warnings, isEmpty);
      expect(result.manifest!.id, 'kovalink-basic');
      expect(result.glb!.triangles, lessThan(5000));
      expect(
        result.glb!.nodeNames,
        containsAll(['Body', 'Wheel_FL', 'Brake_C']),
      );
      expect(result.manifest!.materials.bodyPaint, 'KL_BodyPaint');
    });

    test('bundled toy car pack conforms with a polygon warning', () {
      final result = ModelPackValidator.validate(
        packDirectory('assets/vehicles/toy_car'),
      );
      expect(result.rejection, isNull);
      expect(result.glb!.maxTextureSize, 1024);
      expect(result.warnings.single, contains('권장'));
    });

    test('minimal hand-written pack is accepted', () {
      final result = ModelPackValidator.validate(pack());
      expect(result.accepted, isTrue);
      expect(
        result.files.keys,
        containsAll(['vehicle.json', 'vehicle.glb', 'LICENSE.md']),
      );
    });
  });

  group('archive safety', () {
    test('rejects non-zip data and oversized archives', () {
      expect(
        rejectionCode(Uint8List.fromList(utf8.encode('not a zip'))),
        'not-zip',
      );
      expect(
        rejectionCode(pack(), zipLimits: const ZipLimits(maxArchiveBytes: 100)),
        'archive-too-large',
      );
    });

    test('rejects path traversal, absolute, nested and hidden names', () {
      for (final (name, code) in [
        ('../vehicle.json', 'path-traversal'),
        ('/etc/vehicle.json', 'path-traversal'),
        (r'..\vehicle.json', 'path-traversal'),
        ('C:vehicle.json', 'path-traversal'),
        ('textures/paint.png', 'nested-path'),
        ('textures/', 'nested-path'),
        ('.hidden', 'bad-name'),
      ]) {
        expect(
          rejectionCode(pack(extra: {name: const []})),
          code,
          reason: name,
        );
      }
    });

    test('rejects symlinks and duplicate names', () {
      final symlink = ZipWriter.build([
        const ZipWriterEntry('vehicle.json', [], unixMode: 0xA1FF),
      ]);
      expect(rejectionCode(symlink), 'symlink');
      final duplicate = ZipWriter.build([
        ZipWriterEntry('vehicle.json', utf8.encode('{}')),
        ZipWriterEntry('VEHICLE.json', utf8.encode('{}')),
      ]);
      expect(rejectionCode(duplicate), 'duplicate-entry');
    });

    test('rejects too many entries', () {
      final archive = ZipWriter.build([
        for (var index = 0; index < 17; index++)
          ZipWriterEntry('f$index.txt', const [1]),
      ]);
      expect(rejectionCode(archive), 'too-many-entries');
    });

    test('rejects high-ratio compression bombs before inflating', () {
      final bomb = pack(extra: {'README.md': Uint8List(8 * 1024 * 1024)});
      expect(rejectionCode(bomb), 'compression-bomb');
    });

    test('caps inflation when the header lies about the size', () {
      final lying = ZipWriter.build([
        ZipWriterEntry('vehicle.json', Uint8List(200000), declaredSize: 2000),
      ]);
      expect(rejectionCode(lying), 'compression-bomb');
    });

    test('rejects entries larger than the per-file limit', () {
      expect(
        rejectionCode(pack(), zipLimits: const ZipLimits(maxEntryBytes: 64)),
        'entry-too-large',
      );
    });
  });

  group('pack contents', () {
    test('requires manifest, license and the declared GLB', () {
      expect(
        rejectionCode(
          ZipWriter.build([ZipWriterEntry('LICENSE.md', utf8.encode('x'))]),
        ),
        'missing-manifest',
      );
      expect(rejectionCode(pack(license: false)), 'missing-license');
      expect(
        rejectionCode(
          pack(manifest: manifestJson(overrides: {'asset': 'other.glb'})),
        ),
        'unexpected-file',
      );
    });

    test('refuses scripts and unknown files', () {
      for (final name in ['install.sh', 'loader.js', 'run.exe', 'extra.glb']) {
        expect(
          rejectionCode(pack(extra: {name: utf8.encode('echo hi')})),
          'unexpected-file',
          reason: name,
        );
      }
    });

    test('reports missing required manifest fields', () {
      final manifest = manifestJson()
        ..remove('author')
        ..remove('license');
      final result = ModelPackValidator.validate(pack(manifest: manifest));
      expect(result.rejection!.code, 'manifest-missing-field');
      expect(
        result.rejection!.message,
        allOf(contains('author'), contains('license')),
      );
    });

    test('rejects invalid manifest values', () {
      for (final (overrides, code) in <(Map<String, dynamic>, String)>[
        ({'schemaVersion': 2}, 'manifest-schema'),
        ({'id': 'Bad Id!'}, 'manifest-id'),
        ({'coordinateSystem': 'RH_Z_UP_X_FORWARD'}, 'manifest-axes'),
        ({'origin': 'boundingBoxCenter'}, 'manifest-origin'),
        ({'scale': 0}, 'manifest-scale'),
        ({'asset': '../vehicle.glb'}, 'manifest-asset'),
        (
          {
            'appearance': {'paintColor': 'shiny'},
          },
          'manifest-color',
        ),
        (
          {
            'dimensionsMeters': {
              'length': 470,
              'width': 190,
              'height': 160,
              'wheelbase': 290,
            },
          },
          'manifest-dimensions',
        ),
        (
          {
            'dimensionsMeters': {'length': 4.7},
          },
          'manifest-field',
        ),
      ]) {
        expect(
          rejectionCode(pack(manifest: manifestJson(overrides: overrides))),
          code,
          reason: '$overrides',
        );
      }
    });

    test('rejects broken JSON manifest', () {
      final archive = ZipWriter.build([
        ZipWriterEntry('vehicle.json', utf8.encode('{"schemaVersion": 1,')),
      ]);
      expect(rejectionCode(archive), 'manifest-json');
    });
  });

  group('GLB inspection', () {
    test('rejects external buffers and textures, including data URIs', () {
      for (final glb in [
        buildGlb(
          buffer: {'byteLength': 36, 'uri': 'https://example.com/car.bin'},
        ),
        buildGlb(image: {'uri': 'https://example.com/paint.png'}),
        buildGlb(image: {'uri': 'paint.png'}),
        buildGlb(
          buffer: {
            'byteLength': 36,
            'uri': 'data:application/octet-stream;base64,AAAA',
          },
        ),
      ]) {
        expect(rejectionCode(pack(glb: glb)), 'external-uri');
      }
    });

    test('rejects wrong magic, unsupported required extensions, limits', () {
      expect(
        rejectionCode(pack(glb: buildGlb(magic: 0x12345678))),
        'glb-invalid',
      );
      expect(
        rejectionCode(
          pack(glb: buildGlb(extensionsRequired: ['EXT_unknown_script'])),
        ),
        'glb-extension',
      );
      expect(
        rejectionCode(pack(glb: buildGlb(triangleIndices: 3 * 200001))),
        'too-many-triangles',
      );
      expect(
        rejectionCode(pack(glb: buildGlb(pngSize: (4096, 4096)))),
        'texture-too-large',
      );
    });

    test(
      'accepts allowed textures and warns above the recommended polygon count',
      () {
        final result = ModelPackValidator.validate(
          pack(
            glb: buildGlb(pngSize: (2048, 1024), triangleIndices: 3 * 150000),
          ),
        );
        expect(result.accepted, isTrue);
        expect(result.glb!.maxTextureSize, 2048);
        expect(result.warnings.single, contains('150000'));
      },
    );

    test('warns when manifest names are missing from the GLB', () {
      final result = ModelPackValidator.validate(
        pack(
          manifest: manifestJson(
            overrides: {
              'nodes': {
                'body': 'Body',
                'brakeLights': ['Brake_L'],
              },
              'materials': {'bodyPaint': 'Paint'},
            },
          ),
        ),
      );
      expect(result.accepted, isTrue);
      expect(result.warnings, hasLength(2));
      expect(result.warnings.first, contains('Brake_L'));
    });

    test('reads JPEG frame size', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, //
        0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x00, 0x04, 0x00, 0x03, 0, 0, 0, 0,
      ]);
      expect(GlbInspector.imageSize(jpeg), (1024, 512));
    });
  });

  group('vehicle model library', () {
    late Directory root;
    late VehicleModelLibrary library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kovalink_models_');
      library = VehicleModelLibrary(storageRoot: () async => root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('import, list, load, delete and fall back', () async {
      final outcome = await library.importPack(pack());
      expect(outcome.imported, isTrue);
      expect(outcome.replaced, isFalse);

      final ids = (await library.list()).map((entry) => entry.id).toList();
      expect(ids, ['khronos-toy-car', 'kovalink-basic', 'my-test-car']);

      final loaded = await library.load('my-test-car');
      expect(loaded.manifest.displayName, '내 시험 차');
      expect(loaded.glbAssetPath, startsWith('file://'));
      expect(File(loaded.glbAssetPath!.substring(7)).existsSync(), isTrue);

      expect(await library.delete('my-test-car'), isTrue);
      final fallback = await library.load('my-test-car');
      expect(fallback.manifest.id, VehicleModelLibrary.defaultModelId);
      expect(fallback.warnings.first, contains('기본 모델'));
    });

    test('rejected pack writes nothing to storage', () async {
      final outcome = await library.importPack(
        pack(extra: {'../escape.txt': const []}),
      );
      expect(outcome.imported, isFalse);
      expect(outcome.rejection!.code, 'path-traversal');
      final models = Directory('${root.path}/vehicle_models');
      expect(models.existsSync() ? models.listSync() : const [], isEmpty);
      expect(File('${root.parent.path}/escape.txt').existsSync(), isFalse);
    });

    test(
      're-import replaces, built-in ids are reserved and undeletable',
      () async {
        await library.importPack(pack());
        final again = await library.importPack(pack());
        expect(again.replaced, isTrue);
        final reserved = await library.importPack(
          pack(manifest: manifestJson(overrides: {'id': 'kovalink-basic'})),
        );
        expect(reserved.rejection!.code, 'reserved-id');
        expect(await library.delete('kovalink-basic'), isFalse);
        expect(await library.delete('../etc'), isFalse);
      },
    );

    test('built-in selection and unknown ids load safely', () async {
      final basic = await library.load('kovalink-basic');
      expect(basic.glbAssetPath, 'assets/vehicles/kovalink_basic/vehicle.glb');
      expect(basic.profile.dimensions.wheelbase, 2.8);
      final unknown = await library.load('does-not-exist');
      expect(unknown.manifest.id, VehicleModelLibrary.defaultModelId);
      final defaultModel = await library.load(null);
      expect(defaultModel.warnings, isEmpty);
    });

    test('a corrupted imported manifest falls back to the default', () async {
      await library.importPack(pack());
      File(
        '${root.path}/vehicle_models/my-test-car/vehicle.json',
      ).writeAsStringSync('{');
      final result = await library.load('my-test-car');
      expect(result.manifest.id, VehicleModelLibrary.defaultModelId);
    });
  });
}
