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

    final ipv4 = normalized.split('.').map(int.tryParse).toList();
    if (ipv4.length == 4 &&
        ipv4.every((part) => part != null && part >= 0 && part <= 255)) {
      final first = ipv4[0]!;
      final second = ipv4[1]!;
      return first == 10 ||
          first == 127 ||
          (first == 192 && second == 168) ||
          (first == 172 && second >= 16 && second <= 31);
    }
    return normalized == '::1' ||
        normalized.startsWith('fe80:') ||
        normalized.startsWith('fc') ||
        normalized.startsWith('fd');
  }
}
