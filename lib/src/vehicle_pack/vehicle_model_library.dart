import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kovalink/src/models/vehicle_model_manifest.dart';
import 'package:kovalink/src/services/vehicle_model_repository.dart';
import 'package:kovalink/src/vehicle_pack/model_pack_validator.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

class VehicleModelEntry {
  const VehicleModelEntry({
    required this.id,
    required this.manifest,
    required this.builtIn,
    this.previewPath,
  });

  final String id;
  final VehicleModelManifest manifest;
  final bool builtIn;

  /// Absolute path of preview.png for imported packs that ship one.
  final String? previewPath;
}

class VehicleModelImportOutcome {
  const VehicleModelImportOutcome._({
    this.entry,
    this.rejection,
    this.warnings = const [],
    this.replaced = false,
  });

  final VehicleModelEntry? entry;
  final ModelPackRejection? rejection;
  final List<String> warnings;
  final bool replaced;

  bool get imported => entry != null;
}

/// Built-in and user-imported vehicle model packs.
///
/// Imported packs are validated by [ModelPackValidator] first and then
/// copied into `<storageRoot>/vehicle_models/<id>/`. Nothing in a pack is
/// executed and nothing is fetched from the network.
class VehicleModelLibrary {
  VehicleModelLibrary({required this.storageRoot, this.bundle});

  static const defaultModelId = 'khronos-toy-car';

  /// Built-in packs: asset directory per pack id.
  static const builtInPacks = {
    'khronos-toy-car': 'assets/vehicles/toy_car/',
    'kovalink-basic': 'assets/vehicles/kovalink_basic/',
  };

  /// App storage root (path_provider application support directory).
  final Future<Directory> Function() storageRoot;
  final AssetBundle? bundle;

  Future<Directory> _modelsDirectory() async {
    final root = await storageRoot();
    return Directory('${root.path}/vehicle_models');
  }

  Future<List<VehicleModelEntry>> list() async {
    final entries = <VehicleModelEntry>[];
    for (final MapEntry(key: id, value: directory) in builtInPacks.entries) {
      final result = await VehicleModelRepository.loadBundled(
        bundle: bundle,
        directory: directory,
      );
      entries.add(
        VehicleModelEntry(
          id: id,
          manifest: result.manifest.id == id
              ? result.manifest
              : VehicleModelManifest.builtIn,
          builtIn: true,
        ),
      );
    }
    final models = await _modelsDirectory();
    if (!await models.exists()) return entries;
    final directories = await models
        .list()
        .where((entity) => entity is Directory)
        .cast<Directory>()
        .toList();
    directories.sort((a, b) => a.path.compareTo(b.path));
    for (final directory in directories) {
      final id = directory.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!ModelPackValidator.packId.hasMatch(id)) continue; // .incoming-*
      final result = await _resolveImported(directory);
      if (result.manifest.id != id) continue;
      final preview = File('${directory.path}/preview.png');
      entries.add(
        VehicleModelEntry(
          id: id,
          manifest: result.manifest,
          builtIn: false,
          previewPath: await preview.exists() ? preview.path : null,
        ),
      );
    }
    return entries;
  }

  Future<VehicleModelImportOutcome> importPack(Uint8List archive) async {
    final validation = ModelPackValidator.validate(archive);
    if (!validation.accepted) {
      return VehicleModelImportOutcome._(rejection: validation.rejection);
    }
    final manifest = validation.manifest!;
    if (builtInPacks.containsKey(manifest.id)) {
      return const VehicleModelImportOutcome._(
        rejection: ModelPackRejection(
          'reserved-id',
          '내장 모델과 같은 id는 쓸 수 없습니다. vehicle.json의 id를 바꾸세요.',
        ),
      );
    }
    final models = await _modelsDirectory();
    await models.create(recursive: true);
    final incoming = Directory('${models.path}/.incoming-${manifest.id}');
    if (await incoming.exists()) await incoming.delete(recursive: true);
    await incoming.create();
    for (final MapEntry(key: name, value: bytes) in validation.files.entries) {
      // Names were already restricted to plain root file names.
      SafeZipReader.checkEntryName(name);
      await File('${incoming.path}/$name').writeAsBytes(bytes, flush: true);
    }
    final target = Directory('${models.path}/${manifest.id}');
    final replaced = await target.exists();
    if (replaced) await target.delete(recursive: true);
    await incoming.rename(target.path);
    final preview = File('${target.path}/preview.png');
    return VehicleModelImportOutcome._(
      entry: VehicleModelEntry(
        id: manifest.id,
        manifest: manifest,
        builtIn: false,
        previewPath: await preview.exists() ? preview.path : null,
      ),
      warnings: validation.warnings,
      replaced: replaced,
    );
  }

  /// Deletes an imported pack. Built-in packs cannot be deleted.
  Future<bool> delete(String id) async {
    if (builtInPacks.containsKey(id) ||
        !ModelPackValidator.packId.hasMatch(id)) {
      return false;
    }
    final directory = Directory('${(await _modelsDirectory()).path}/$id');
    if (!await directory.exists()) return false;
    await directory.delete(recursive: true);
    return true;
  }

  /// Loads the selected pack. Unknown ids, missing files and broken packs
  /// fall back to the built-in default model with a warning.
  Future<VehicleModelLoadResult> load(String? id) async {
    final selected = id ?? defaultModelId;
    final builtInDirectory = builtInPacks[selected];
    if (builtInDirectory != null) {
      return VehicleModelRepository.loadBundled(
        bundle: bundle,
        directory: builtInDirectory,
      );
    }
    VehicleModelLoadResult? result;
    if (ModelPackValidator.packId.hasMatch(selected)) {
      final directory = Directory(
        '${(await _modelsDirectory()).path}/$selected',
      );
      if (await directory.exists()) {
        result = await _resolveImported(directory);
        if (result.manifest.id != selected || result.glbAssetPath == null) {
          result = null;
        }
      }
    }
    if (result != null) return result;
    final fallback = await VehicleModelRepository.loadBundled(
      bundle: bundle,
      directory: builtInPacks[defaultModelId]!,
    );
    return VehicleModelLoadResult(
      manifest: fallback.manifest,
      glbAssetPath: fallback.glbAssetPath,
      warnings: [
        '선택한 차량 모델($selected)을 불러올 수 없어 기본 모델로 돌아갑니다.',
        ...fallback.warnings,
      ],
    );
  }

  Future<VehicleModelLoadResult> _resolveImported(Directory directory) async {
    final manifestFile = File('${directory.path}/vehicle.json');
    try {
      final decoded = jsonDecode(await manifestFile.readAsString());
      final result = VehicleModelRepository.resolve(
        decoded,
        directory: directory.uri.toFilePath(),
      );
      final glbPath = result.glbAssetPath;
      if (glbPath == null || !await File(glbPath).exists()) {
        return VehicleModelLoadResult(
          manifest: result.manifest,
          glbAssetPath: null,
          warnings: [...result.warnings, 'GLB 파일이 없어 기본 내장 모델을 그립니다.'],
        );
      }
      // Native loader (thermion) reads app files through file:// paths.
      return VehicleModelLoadResult(
        manifest: result.manifest,
        glbAssetPath: 'file://$glbPath',
        warnings: result.warnings,
      );
    } on Object catch (error) {
      return VehicleModelLoadResult(
        manifest: VehicleModelManifest.builtIn,
        glbAssetPath: null,
        warnings: ['가져온 모델을 읽을 수 없습니다: $error'],
      );
    }
  }
}
