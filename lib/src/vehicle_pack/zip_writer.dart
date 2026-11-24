import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kovalink/src/vehicle_pack/safe_zip_reader.dart';

/// One entry for [ZipWriter]. The override fields exist so tests can build
/// deliberately broken archives (lying sizes, traversal names, symlinks).
class ZipWriterEntry {
  const ZipWriterEntry(
    this.name,
    this.content, {
    this.deflate = true,
    this.declaredSize,
    this.unixMode,
  });

  final String name;
  final List<int> content;
  final bool deflate;
  final int? declaredSize;
  final int? unixMode;
}

/// Small ZIP writer used by the example-pack tool and by tests. The app
/// itself only reads packs.
class ZipWriter {
  const ZipWriter._();

  static Uint8List build(List<ZipWriterEntry> entries) {
    final out = BytesBuilder();
    final central = BytesBuilder();
    for (final entry in entries) {
      final name = utf8.encode(entry.name);
      final raw = Uint8List.fromList(entry.content);
      final compressed = entry.deflate
          ? Uint8List.fromList(ZLibEncoder(raw: true, level: 9).convert(raw))
          : raw;
      final crc = Crc32.of(raw);
      final size = entry.declaredSize ?? raw.length;
      final method = entry.deflate ? 8 : 0;
      final offset = out.length;

      final local = ByteData(30);
      local
        ..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)
        ..setUint16(6, 0x0800, Endian.little)
        ..setUint16(8, method, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, compressed.length, Endian.little)
        ..setUint32(22, size, Endian.little)
        ..setUint16(26, name.length, Endian.little);
      out
        ..add(local.buffer.asUint8List())
        ..add(name)
        ..add(compressed);

      final header = ByteData(46);
      header
        ..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 0x0314, Endian.little)
        ..setUint16(6, 20, Endian.little)
        ..setUint16(8, 0x0800, Endian.little)
        ..setUint16(10, method, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, compressed.length, Endian.little)
        ..setUint32(24, size, Endian.little)
        ..setUint16(28, name.length, Endian.little)
        ..setUint32(38, (entry.unixMode ?? 0x81A4) << 16, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central
        ..add(header.buffer.asUint8List())
        ..add(name);
    }
    final centralOffset = out.length;
    final centralBytes = central.takeBytes();
    out.add(centralBytes);
    final end = ByteData(22);
    end
      ..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, entries.length, Endian.little)
      ..setUint16(10, entries.length, Endian.little)
      ..setUint32(12, centralBytes.length, Endian.little)
      ..setUint32(16, centralOffset, Endian.little);
    out.add(end.buffer.asUint8List());
    return out.takeBytes();
  }
}
