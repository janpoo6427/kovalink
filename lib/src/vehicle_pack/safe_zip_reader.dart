import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Why a model pack was refused. [code] is stable for tests and logs;
/// [message] is shown to the user.
class ModelPackRejection implements Exception {
  const ModelPackRejection(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ModelPackRejection($code): $message';
}

class ZipLimits {
  const ZipLimits({
    this.maxArchiveBytes = 32 * 1024 * 1024,
    this.maxEntries = 16,
    this.maxEntryBytes = 24 * 1024 * 1024,
    this.maxTotalBytes = 32 * 1024 * 1024,
    this.maxCompressionRatio = 100,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  /// Uncompressed/compressed size ratio above which an entry is treated as
  /// a decompression bomb. Real GLB/PNG/JSON content stays far below 100.
  final int maxCompressionRatio;
}

/// Minimal, defensive ZIP reader for `.kovamodel` packs.
///
/// Only flat archives with stored (0) or deflate (8) entries are accepted.
/// Sizes are checked from the central directory before anything is
/// inflated, and inflation is streamed with a hard output cap, so a lying
/// header cannot expand into an unbounded allocation. Nothing in the archive
/// is ever executed.
class SafeZipReader {
  const SafeZipReader._();

  static const _eocdSignature = 0x06054b50;
  static const _centralSignature = 0x02014b50;
  static const _localSignature = 0x04034b50;

  static Map<String, Uint8List> read(
    Uint8List bytes, {
    ZipLimits limits = const ZipLimits(),
  }) {
    if (bytes.length > limits.maxArchiveBytes) {
      throw ModelPackRejection(
        'archive-too-large',
        '파일이 너무 큽니다(${_mb(bytes.length)} MB, 최대 ${_mb(limits.maxArchiveBytes)} MB).',
      );
    }
    final data = ByteData.sublistView(bytes);
    final eocd = _findEndOfCentralDirectory(bytes, data);
    final diskNumber = data.getUint16(eocd + 4, Endian.little);
    final centralDisk = data.getUint16(eocd + 6, Endian.little);
    final entryCount = data.getUint16(eocd + 10, Endian.little);
    final centralSize = data.getUint32(eocd + 12, Endian.little);
    final centralOffset = data.getUint32(eocd + 16, Endian.little);
    if (diskNumber != 0 || centralDisk != 0) {
      throw const ModelPackRejection('multi-disk', '분할 압축 파일은 지원하지 않습니다.');
    }
    if (entryCount == 0xFFFF ||
        centralOffset == 0xFFFFFFFF ||
        centralSize == 0xFFFFFFFF) {
      throw const ModelPackRejection('zip64', 'ZIP64 형식은 지원하지 않습니다.');
    }
    if (entryCount > limits.maxEntries) {
      throw ModelPackRejection(
        'too-many-entries',
        '파일 개수가 너무 많습니다($entryCount개, 최대 ${limits.maxEntries}개).',
      );
    }
    if (centralOffset + centralSize > eocd) {
      throw const ModelPackRejection('corrupt', 'ZIP 목차가 손상되었습니다.');
    }

    final entries = <_Entry>[];
    var cursor = centralOffset;
    var declaredTotal = 0;
    for (var index = 0; index < entryCount; index++) {
      if (cursor + 46 > eocd ||
          data.getUint32(cursor, Endian.little) != _centralSignature) {
        throw const ModelPackRejection('corrupt', 'ZIP 목차가 손상되었습니다.');
      }
      final flags = data.getUint16(cursor + 8, Endian.little);
      final method = data.getUint16(cursor + 10, Endian.little);
      final crc = data.getUint32(cursor + 16, Endian.little);
      final compressedSize = data.getUint32(cursor + 20, Endian.little);
      final size = data.getUint32(cursor + 24, Endian.little);
      final nameLength = data.getUint16(cursor + 28, Endian.little);
      final extraLength = data.getUint16(cursor + 30, Endian.little);
      final commentLength = data.getUint16(cursor + 32, Endian.little);
      final externalAttributes = data.getUint32(cursor + 38, Endian.little);
      final localOffset = data.getUint32(cursor + 42, Endian.little);
      final nameEnd = cursor + 46 + nameLength;
      if (nameEnd > eocd) {
        throw const ModelPackRejection('corrupt', 'ZIP 목차가 손상되었습니다.');
      }
      final String name;
      try {
        name = utf8.decode(bytes.sublist(cursor + 46, nameEnd));
      } on FormatException {
        throw const ModelPackRejection('bad-name', '파일 이름 인코딩이 올바르지 않습니다.');
      }
      cursor = nameEnd + extraLength + commentLength;

      if (flags & 0x1 != 0) {
        throw const ModelPackRejection('encrypted', '암호화된 압축 파일은 지원하지 않습니다.');
      }
      // Unix symlink entries (S_IFLNK in the high 16 bits).
      if ((externalAttributes >> 16) & 0xF000 == 0xA000) {
        throw ModelPackRejection('symlink', '심볼릭 링크는 허용하지 않습니다: $name');
      }
      if (name.endsWith('/')) {
        if (size != 0) {
          throw ModelPackRejection('bad-name', '폴더 항목이 올바르지 않습니다: $name');
        }
        throw ModelPackRejection(
          'nested-path',
          '모델 팩은 폴더 없이 파일만 담아야 합니다: $name',
        );
      }
      checkEntryName(name);
      if (method != 0 && method != 8) {
        throw ModelPackRejection(
          'unsupported-compression',
          '지원하지 않는 압축 방식입니다($method): $name',
        );
      }
      if (size > limits.maxEntryBytes) {
        throw ModelPackRejection(
          'entry-too-large',
          '$name 파일이 너무 큽니다(${_mb(size)} MB, 최대 ${_mb(limits.maxEntryBytes)} MB).',
        );
      }
      declaredTotal += size;
      if (declaredTotal > limits.maxTotalBytes) {
        throw ModelPackRejection(
          'total-too-large',
          '압축을 푼 전체 크기가 너무 큽니다(최대 ${_mb(limits.maxTotalBytes)} MB).',
        );
      }
      if (method == 0 && compressedSize != size) {
        throw ModelPackRejection('corrupt', '$name 크기 정보가 맞지 않습니다.');
      }
      if (method == 8 &&
          size > 4096 &&
          size > compressedSize * limits.maxCompressionRatio) {
        throw ModelPackRejection(
          'compression-bomb',
          '$name 압축률이 비정상적으로 높습니다(압축 폭탄 의심).',
        );
      }
      if (entries.any(
        (entry) => entry.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw ModelPackRejection(
          'duplicate-entry',
          '같은 이름의 파일이 두 번 있습니다: $name',
        );
      }
      entries.add(_Entry(name, method, crc, compressedSize, size, localOffset));
    }

    final files = <String, Uint8List>{};
    for (final entry in entries) {
      files[entry.name] = _extract(bytes, data, entry, eocd);
    }
    return files;
  }

  /// Rejects anything other than a plain file name at the archive root.
  static void checkEntryName(String name) {
    if (name.isEmpty || name.length > 64) {
      throw ModelPackRejection('bad-name', '파일 이름이 올바르지 않습니다: $name');
    }
    if (name.startsWith('/') ||
        name.contains('\\') ||
        name.contains(':') ||
        name.split('/').contains('..')) {
      throw ModelPackRejection(
        'path-traversal',
        '경로 탈출 시도가 있는 파일 이름입니다: $name',
      );
    }
    if (name.contains('/')) {
      throw ModelPackRejection('nested-path', '모델 팩은 폴더 없이 파일만 담아야 합니다: $name');
    }
    if (name.startsWith('.') ||
        name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7F)) {
      throw ModelPackRejection('bad-name', '숨김·제어 문자 파일 이름은 허용하지 않습니다: $name');
    }
  }

  static int _findEndOfCentralDirectory(Uint8List bytes, ByteData data) {
    if (bytes.length < 22) {
      throw const ModelPackRejection('not-zip', 'ZIP(.kovamodel) 파일이 아닙니다.');
    }
    final earliest = bytes.length - 22 - 0xFFFF;
    for (
      var offset = bytes.length - 22;
      offset >= 0 && offset >= earliest;
      offset--
    ) {
      if (data.getUint32(offset, Endian.little) == _eocdSignature) {
        return offset;
      }
    }
    throw const ModelPackRejection('not-zip', 'ZIP(.kovamodel) 파일이 아닙니다.');
  }

  static Uint8List _extract(
    Uint8List bytes,
    ByteData data,
    _Entry entry,
    int limit,
  ) {
    final local = entry.localOffset;
    if (local + 30 > limit ||
        data.getUint32(local, Endian.little) != _localSignature) {
      throw ModelPackRejection('corrupt', '${entry.name} 위치 정보가 손상되었습니다.');
    }
    final nameLength = data.getUint16(local + 26, Endian.little);
    final extraLength = data.getUint16(local + 28, Endian.little);
    final start = local + 30 + nameLength + extraLength;
    final end = start + entry.compressedSize;
    if (end > limit) {
      throw ModelPackRejection('corrupt', '${entry.name} 데이터가 잘렸습니다.');
    }
    final compressed = Uint8List.sublistView(bytes, start, end);
    final Uint8List output;
    if (entry.method == 0) {
      output = Uint8List.fromList(compressed);
    } else {
      output = _inflateCapped(compressed, entry.size, entry.name);
    }
    if (output.length != entry.size) {
      throw ModelPackRejection('corrupt', '${entry.name} 크기 정보가 맞지 않습니다.');
    }
    if (Crc32.of(output) != entry.crc) {
      throw ModelPackRejection('crc', '${entry.name} 무결성(CRC) 검사에 실패했습니다.');
    }
    return output;
  }

  static Uint8List _inflateCapped(Uint8List compressed, int cap, String name) {
    final sink = _CappedSink(cap, name);
    final input = ZLibDecoder(raw: true).startChunkedConversion(sink);
    const chunk = 4096;
    try {
      for (var offset = 0; offset < compressed.length; offset += chunk) {
        final end = offset + chunk < compressed.length
            ? offset + chunk
            : compressed.length;
        input.add(Uint8List.sublistView(compressed, offset, end));
      }
      input.close();
    } on ModelPackRejection {
      rethrow;
    } on Object {
      throw ModelPackRejection('corrupt', '$name 압축을 풀 수 없습니다.');
    }
    return sink.takeBytes();
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}

class _Entry {
  const _Entry(
    this.name,
    this.method,
    this.crc,
    this.compressedSize,
    this.size,
    this.localOffset,
  );

  final String name;
  final int method;
  final int crc;
  final int compressedSize;
  final int size;
  final int localOffset;
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.cap, this.name);

  final int cap;
  final String name;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > cap) {
      throw ModelPackRejection(
        'compression-bomb',
        '$name 압축을 풀면 적힌 크기보다 커집니다(압축 폭탄 의심).',
      );
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

class Crc32 {
  const Crc32._();

  static final Uint32List _table = () {
    final table = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }();

  static int of(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final byte in bytes) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
