import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:kovalink/src/settings/app_settings.dart';
import 'package:kovalink/src/vehicle_pack/model_pack_validator.dart';
import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';
import 'package:kovalink/src/vehicle_pack/vehicle_model_library.dart';

/// Returns the bytes of a user-chosen `.kovamodel`, or null if cancelled.
typedef ModelFilePicker = Future<Uint8List?> Function();

/// Default picker: the platform's document picker (file_picker, MIT).
/// The file is size-checked before it is read into memory.
Future<Uint8List?> pickModelFileWithSystemPicker() async {
  final file = await FilePicker.pickFile(
    dialogTitle: '차량 모델 파일(.kovamodel) 선택',
  );
  if (file == null) return null;
  final length = await file.length();
  if (length != null && length > const ZipLimits().maxArchiveBytes) {
    throw const ModelPackRejection(
      'archive-too-large',
      '파일이 너무 큽니다(최대 32 MB).',
    );
  }
  return file.readAsBytes();
}

/// Pick → validate → copy into app storage → select. Shows the outcome in a
/// dialog. Nothing from the file is executed; no network is used.
class VehicleModelImportFlow {
  const VehicleModelImportFlow._();

  static Future<VehicleModelImportOutcome?> run(
    BuildContext context, {
    required VehicleModelLibrary library,
    required SettingsController settings,
    ModelFilePicker picker = pickModelFileWithSystemPicker,
  }) async {
    Uint8List? bytes;
    String? pickError;
    try {
      bytes = await picker();
    } on ModelPackRejection catch (rejection) {
      pickError = rejection.message;
    } on Object catch (error) {
      pickError = '파일을 열 수 없습니다: $error';
    }
    if (!context.mounted) return null;
    if (pickError != null) {
      await _show(
        context,
        title: '가져오기 실패',
        lines: [pickError],
        success: false,
      );
      return null;
    }
    if (bytes == null) return null;
    final outcome = await library.importPack(bytes);
    if (!context.mounted) return outcome;
    final entry = outcome.entry;
    if (entry == null) {
      await _show(
        context,
        title: '가져오기 거부',
        lines: [outcome.rejection!.message, '(${outcome.rejection!.code})'],
        success: false,
      );
      return outcome;
    }
    await settings.update((s) => s.copyWith(vehicleModelId: entry.id));
    if (!context.mounted) return outcome;
    await _show(
      context,
      title: outcome.replaced ? '차량 모델을 교체했습니다' : '차량 모델을 가져왔습니다',
      lines: [
        '${entry.manifest.displayName} · ${entry.manifest.author} · ${entry.manifest.license}',
        ...outcome.warnings,
      ],
      success: true,
    );
    return outcome;
  }

  static Future<void> _show(
    BuildContext context, {
    required String title,
    required List<String> lines,
    required bool success,
  }) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(
        success ? Icons.check_circle_outline : Icons.block_outlined,
        color: success
            ? const Color(0xFF58F2C2)
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final line in lines) Text(line)],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('확인'),
        ),
      ],
    ),
  );
}

/// File-name hint for the picker dialog and docs.
const kovaModelExtension = ModelPackValidator.fileExtension;
