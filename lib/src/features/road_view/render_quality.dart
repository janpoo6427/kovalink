/// 설정 → 화질. One finished choice per mode, no candidate variants.
enum RenderQuality {
  /// Default: GPU (Filament PBR) where the device supports it, falling back
  /// to the software renderer if the GPU view cannot start or is too slow.
  auto,

  /// Always the GPU renderer when the platform has it.
  high,

  /// Software renderer (low-end phones, battery saving, tests).
  saver,
}

class RenderQualityPolicy {
  const RenderQualityPolicy._();

  static bool useGpu(RenderQuality quality, {required bool gpuAvailable}) =>
      switch (quality) {
        RenderQuality.auto || RenderQuality.high => gpuAvailable,
        RenderQuality.saver => false,
      };

  static String label(RenderQuality quality) => switch (quality) {
    RenderQuality.auto => '자동',
    RenderQuality.high => '고품질',
    RenderQuality.saver => '절약',
  };
}
