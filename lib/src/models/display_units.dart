/// Display units (설정 → 단위). Only speeds are converted; distances stay
/// metric because navigation distances arrive in meters.
enum SpeedUnit { kph, mph }

extension SpeedUnitFormat on SpeedUnit {
  String get label => switch (this) {
    SpeedUnit.kph => 'km/h',
    SpeedUnit.mph => 'mph',
  };

  double fromMps(double mps) => switch (this) {
    SpeedUnit.kph => mps * 3.6,
    SpeedUnit.mph => mps * 2.2369362920544,
  };

  double fromKph(double kph) => switch (this) {
    SpeedUnit.kph => kph,
    SpeedUnit.mph => kph / 1.609344,
  };

  /// Rounded integer for display; negative or non-finite values show 0.
  int roundedFromMps(double mps) {
    final value = fromMps(mps);
    return value.isFinite && value > 0 ? value.round() : 0;
  }
}

/// `545 m`, `1.1 km`, `17.5 km`, `120 km`.
String formatDistance(double meters) {
  if (!meters.isFinite || meters < 0) return '–';
  if (meters < 1000) return '${meters.round()} m';
  final km = meters / 1000;
  return km < 100 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
}

/// Compact form used on signs: `42m`, `1.2km`.
String formatDistanceCompact(double meters) =>
    formatDistance(meters).replaceAll(' ', '');

/// `12분`, `1시간 0분`.
String formatDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  return hours > 0 ? '$hours시간 $minutes분' : '$minutes분';
}
