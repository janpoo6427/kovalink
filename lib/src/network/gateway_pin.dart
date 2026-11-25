// The comma's identity on Wi-Fi: the SHA-256 of the public key
// (DER SubjectPublicKeyInfo) in the certificate it presents. The pin stays
// the same when the comma gets a new IP address, so KovaLink recognizes the
// same comma without checking the address in the certificate.
//
// The administrator reads the pin from the comma's server.pem
// ([kovaPinCommand]) and the user pastes it, or picks server.pem itself and
// KovaLink computes it ([GatewayPin.fromPem]). A pin is never taken from
// the network on first sight (no trust on first use).
import 'dart:convert';
import 'dart:io' show X509Certificate;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Shell line for the administrator, run on the comma.
const kovaPinCommand =
    'openssl x509 -in /persist/kova/gateway/server.pem -noout -pubkey '
    '| openssl pkey -pubin -outform DER | sha256sum';

@immutable
class GatewayPin {
  GatewayPin._(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 32) throw ArgumentError('a pin is 32 bytes');
  }

  /// Pin of a DER SubjectPublicKeyInfo.
  factory GatewayPin.ofSpki(List<int> spkiDer) =>
      GatewayPin._(sha256.convert(spkiDer).bytes);

  /// Pin of a DER X.509 certificate, or null when it cannot be read.
  static GatewayPin? ofCertificateDer(List<int> der) {
    final spki = subjectPublicKeyInfoOf(der);
    return spki == null ? null : GatewayPin.ofSpki(spki);
  }

  static GatewayPin? ofCertificate(X509Certificate? certificate) {
    if (certificate == null) return null;
    try {
      return ofCertificateDer(certificate.der);
    } on Object {
      return null;
    }
  }

  /// Reads a pasted pin: 64 hex digits (spaces, colons and the `  -` that
  /// sha256sum prints are ignored) or the 32 bytes in base64
  /// (`sha256/` prefix allowed).
  static GatewayPin? tryParse(String text) {
    final value = text.trim();
    if (value.isEmpty) return null;
    if (value.toLowerCase().startsWith('sha256/')) {
      return _base64(value.substring(7));
    }
    final compact = value.replaceAll(RegExp(r'[\s:]'), '');
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(compact)) {
      return GatewayPin._(_hexBytes(compact));
    }
    final hex = RegExp(
      r'(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])',
    ).allMatches(value).toList();
    if (hex.length == 1) return GatewayPin._(_hexBytes(hex.single.group(0)!));
    return _base64(value.replaceAll(RegExp(r'\s'), ''));
  }

  /// From a stored [hex] value.
  static GatewayPin? fromHex(String? hex) {
    if (hex == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    return GatewayPin._(_hexBytes(hex));
  }

  final Uint8List bytes;

  /// 64 lowercase hex digits (stored form, same as sha256sum prints).
  String get hex =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String get asBase64 => base64Encode(bytes);

  /// For reading aloud and comparing on screen: `ab12 cd34 …` (16 groups).
  String get grouped =>
      [for (var i = 0; i < 64; i += 4) hex.substring(i, i + 4)].join(' ');

  /// First and last groups, for small rows: `ab12 cd34 … 9f0e`.
  String get short =>
      '${hex.substring(0, 4)} ${hex.substring(4, 8)} … ${hex.substring(60)}';

  /// Constant-time comparison.
  bool matches(GatewayPin? other) {
    if (other == null) return false;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= bytes[i] ^ other.bytes[i];
    }
    return diff == 0;
  }

  @override
  bool operator ==(Object other) => other is GatewayPin && matches(other);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'GatewayPin($short)';

  static GatewayPin? _base64(String value) {
    if (value.isEmpty) return null;
    try {
      final normalized = base64.normalize(
        value.replaceAll('-', '+').replaceAll('_', '/'),
      );
      final decoded = base64Decode(normalized);
      return decoded.length == 32 ? GatewayPin._(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static List<int> _hexBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// The comma presented a certificate whose pin is not the registered one.
/// Nothing was sent on that connection.
class GatewayIdentityMismatch implements Exception {
  const GatewayIdentityMismatch(this.presented);

  /// Pin of the certificate that was presented; null when unreadable.
  final GatewayPin? presented;

  @override
  String toString() => 'GatewayIdentityMismatch(${presented?.short})';
}

/// A request for another address than the session's comma.
class GatewayOriginRefused implements Exception {
  const GatewayOriginRefused(this.uri);
  final Uri uri;

  @override
  String toString() => 'GatewayOriginRefused($uri)';
}

/// What a picked PEM file gave.
sealed class PemPinResult {
  const PemPinResult();
}

class PemPinFound extends PemPinResult {
  const PemPinFound(this.pin, {required this.fromCertificate});
  final GatewayPin pin;

  /// True for a CERTIFICATE block, false for a PUBLIC KEY block.
  final bool fromCertificate;
}

class PemPinRefused extends PemPinResult {
  const PemPinRefused(this.reason);

  /// Korean, user-facing.
  final String reason;
}

abstract final class PemPinText {
  static const privateKey =
      '이 파일은 개인 키예요. 개인 키는 휴대폰에 넣지 않아요. server.pem을 골라 주세요.';
  static const noCertificate = '인증서를 찾지 못했어요. 콤마의 server.pem을 골라 주세요.';
  static const unreadable = '인증서를 읽지 못했어요. 파일이 맞는지 확인해 주세요.';
}

final RegExp _pemBlock = RegExp(
  r'-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----',
);

/// Pin from the text of a PEM file: the first CERTIFICATE (the comma's own
/// certificate comes first in server.pem), else a PUBLIC KEY. A private key
/// is refused and never kept.
PemPinResult pinFromPem(String text) {
  final blocks = _pemBlock.allMatches(text).toList();
  if (blocks.isEmpty) {
    if (text.contains('PRIVATE KEY')) {
      return const PemPinRefused(PemPinText.privateKey);
    }
    return const PemPinRefused(PemPinText.noCertificate);
  }
  List<int>? decode(RegExpMatch block) {
    try {
      return base64Decode(block.group(2)!.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return null;
    }
  }

  for (final block in blocks) {
    if (block.group(1) != 'CERTIFICATE') continue;
    final der = decode(block);
    final pin = der == null ? null : GatewayPin.ofCertificateDer(der);
    return pin == null
        ? const PemPinRefused(PemPinText.unreadable)
        : PemPinFound(pin, fromCertificate: true);
  }
  for (final block in blocks) {
    if (block.group(1) != 'PUBLIC KEY') continue;
    final der = decode(block);
    if (der == null || _readTlv(der, 0)?.tag != 0x30) {
      return const PemPinRefused(PemPinText.unreadable);
    }
    return PemPinFound(GatewayPin.ofSpki(der), fromCertificate: false);
  }
  if (blocks.any((b) => b.group(1)!.contains('PRIVATE KEY'))) {
    return const PemPinRefused(PemPinText.privateKey);
  }
  return const PemPinRefused(PemPinText.noCertificate);
}

class _Tlv {
  const _Tlv(this.tag, this.start, this.contentStart, this.end);
  final int tag;
  final int start;
  final int contentStart;
  final int end;
}

/// One DER element at [offset] (single-byte tags, definite lengths only).
_Tlv? _readTlv(List<int> der, int offset) {
  if (offset + 2 > der.length) return null;
  final tag = der[offset];
  if (tag & 0x1f == 0x1f) return null;
  var index = offset + 1;
  final first = der[index++];
  int length;
  if (first < 0x80) {
    length = first;
  } else {
    final count = first & 0x7f;
    if (count == 0 || count > 4 || index + count > der.length) return null;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[index++];
    }
  }
  final end = index + length;
  if (end > der.length) return null;
  return _Tlv(tag, offset, index, end);
}

/// The DER SubjectPublicKeyInfo inside a DER certificate, or null.
///
/// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version
/// OPTIONAL, serialNumber, signature, issuer, validity, subject,
/// subjectPublicKeyInfo, ... }, ... }
List<int>? subjectPublicKeyInfoOf(List<int> der) {
  final certificate = _readTlv(der, 0);
  if (certificate == null || certificate.tag != 0x30) return null;
  final tbs = _readTlv(der, certificate.contentStart);
  if (tbs == null || tbs.tag != 0x30) return null;
  var cursor = tbs.contentStart;
  final fields = <_Tlv>[];
  while (cursor < tbs.end && fields.length < 7) {
    final field = _readTlv(der, cursor);
    if (field == null || field.end > tbs.end) return null;
    fields.add(field);
    cursor = field.end;
  }
  final skip = fields.isNotEmpty && fields.first.tag == 0xa0 ? 1 : 0;
  if (fields.length < skip + 6) return null;
  final spki = fields[skip + 5];
  if (spki.tag != 0x30) return null;
  return der.sublist(spki.start, spki.end);
}
