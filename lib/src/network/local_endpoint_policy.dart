class LocalEndpointPolicy {
  const LocalEndpointPolicy._();

  static String? validate(String value) {
    return _validate(value, const {
      'ws',
      'wss',
    }, 'WebSocket 주소(ws:// 또는 wss://)만 지원합니다.');
  }

  static String? validateSignaling(String value) {
    return _validate(value, const {
      'http',
      'https',
    }, 'HTTP signaling 주소(http:// 또는 https://)만 지원합니다.');
  }

  static String? _validate(
    String value,
    Set<String> schemes,
    String schemeError,
  ) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '올바른 gateway 주소를 입력하세요.';
    }
    if (!schemes.contains(uri.scheme)) {
      return schemeError;
    }
    if (!_isLocalHost(uri.host)) {
      return 'KovaLink는 로컬·사설 네트워크 gateway에만 연결합니다.';
    }
    return null;
  }

  static bool _isLocalHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized.endsWith('.local')) return true;

    // A URI host contains ':' only when it came from a bracketed IPv6 literal.
    // IPv6 ranges must never be matched against plain hostnames.
    if (normalized.contains(':')) return _isLocalIPv6Literal(normalized);

    final ipv4 = _parseCanonicalIPv4(normalized);
    if (ipv4 == null) return false;
    final first = ipv4[0];
    final second = ipv4[1];
    return first == 10 ||
        first == 127 ||
        (first == 192 && second == 168) ||
        (first == 172 && second >= 16 && second <= 31);
  }

  /// Loopback (::1), unique-local (fc00::/7) or link-local (fe80::/16, same as the previous fe80: prefix rule).
  static bool _isLocalIPv6Literal(String host) {
    final zoneStart = host.indexOf('%');
    final address = zoneStart < 0 ? host : host.substring(0, zoneStart);
    final List<int> bytes;
    try {
      bytes = Uri.parseIPv6Address(address);
    } on FormatException {
      return false;
    }
    final isLoopback =
        bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    final isUniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final isLinkLocal = bytes[0] == 0xfe && bytes[1] == 0x80;
    return isLoopback || isUniqueLocal || isLinkLocal;
  }

  static final RegExp _ipv4Octet = RegExp(r'^(0|[1-9][0-9]{0,2})$');

  /// Strict dotted-decimal only. Resolvers read forms such as `010.0.0.1`
  /// (octal) or `0xa.0.0.1` (hex) differently from int.tryParse.
  static List<int>? _parseCanonicalIPv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      if (!_ipv4Octet.hasMatch(part)) return null;
      final value = int.parse(part);
      if (value > 255) return null;
      octets.add(value);
    }
    return octets;
  }
}
