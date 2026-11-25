class LocalEndpointPolicy {
  const LocalEndpointPolicy._();

  static String? validate(String value) {
    return _validate(value, const {
      'ws',
      'wss',
    }, '주소는 ws:// 또는 wss://로 시작해야 해요.');
  }

  static String? validateSignaling(String value) {
    return _validate(value, const {
      'http',
      'https',
    }, '주소는 http:// 또는 https://로 시작해야 해요.');
  }

  /// kovapilot settings API origin, e.g. `https://192.168.43.20:8082`. Only the
  /// origin is used; a path other than `/` is refused so the app always
  /// calls the documented `/v1/...` routes.
  static String? validateSettings(String value) {
    final error = _validate(value, const {
      'http',
      'https',
    }, '주소는 http:// 또는 https://로 시작해야 해요.');
    if (error != null) return error;
    final uri = Uri.parse(value.trim());
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      return '주소와 포트까지만 적어 주세요. 예: https://192.168.43.20:8082';
    }
    return null;
  }

  /// Origin of an accepted settings address (call [validateSettings] first).
  static Uri settingsBase(String value) {
    final uri = Uri.parse(value.trim());
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  /// True only for `localhost`, `127.0.0.1` and `::1`: the gateway's
  /// loopback-only development bind. Every other private address is LAN.
  static bool isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'localhost' || normalized == '127.0.0.1') return true;
    if (!normalized.contains(':')) return false;
    try {
      final bytes = Uri.parseIPv6Address(normalized);
      return bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
    } on FormatException {
      return false;
    }
  }

  static String? _validate(
    String value,
    Set<String> schemes,
    String schemeError,
  ) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '주소를 다시 확인해 주세요.';
    }
    if (!schemes.contains(uri.scheme)) {
      return schemeError;
    }
    if (!_isLocalHost(uri.host)) {
      return '같은 네트워크 안의 주소만 쓸 수 있어요.';
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
