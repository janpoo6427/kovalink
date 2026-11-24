import 'package:kovalink/src/models/vehicle_model_manifest.dart';

/// Render parameters for the user's own vehicle, derived from a model pack
/// manifest. Everything here is display-only; nothing is sent to the car.
///
/// Units: meters. Road-scene frame: `x` forward, `y` left, origin on the
/// ground at the ego front bumper center, so object distances are gaps
/// (see docs/ROAD_SCENE.md). The GLB keeps its own pack frame.
class EgoVehicleProfile {
  const EgoVehicleProfile({
    required this.displayName,
    required this.dimensions,
    required this.appearance,
  });

  factory EgoVehicleProfile.fromManifest(VehicleModelManifest manifest) {
    final dimensions = manifest.dimensions.validationError == null
        ? manifest.dimensions
        : VehicleDimensions.reference;
    return EgoVehicleProfile(
      displayName: manifest.displayName,
      dimensions: dimensions,
      appearance: manifest.appearance,
    );
  }

  static const builtIn = EgoVehicleProfile(
    displayName: '기본 내장 차량',
    dimensions: VehicleDimensions.reference,
    appearance: VehicleAppearance(),
  );

  final String displayName;
  final VehicleDimensions dimensions;
  final VehicleAppearance appearance;

  static const _reference = VehicleDimensions.reference;

  /// On-screen width relative to the reference car in the chase view.
  /// Clamped so an unusual pack cannot cover the whole road or vanish.
  double get chaseWidthScale =>
      (dimensions.width / _reference.width).clamp(0.75, 1.35);

  /// Rear-view body height as a fraction of body width. The reference car
  /// gives the renderer's original 0.58.
  double get chaseHeightRatio {
    const referenceRatio = 1.48 / 1.86;
    final ratio = dimensions.height / dimensions.width;
    return (0.58 * ratio / referenceRatio).clamp(0.42, 0.95);
  }

  /// Overhang beyond each axle, assuming the wheelbase is centered in the
  /// body. Used to place wheels in the top-down view.
  double get overhangMeters => (dimensions.length - dimensions.wheelbase) / 2;

  /// Rear bumper position in the road-scene frame (front bumper is x = 0).
  double get rearBumperForwardMeters => -dimensions.length;

  double get frontAxleForwardMeters => -overhangMeters;

  double get rearAxleForwardMeters => -overhangMeters - dimensions.wheelbase;

  @override
  bool operator ==(Object other) =>
      other is EgoVehicleProfile &&
      other.displayName == displayName &&
      other.dimensions.length == dimensions.length &&
      other.dimensions.width == dimensions.width &&
      other.dimensions.height == dimensions.height &&
      other.dimensions.wheelbase == dimensions.wheelbase &&
      other.appearance.paintArgb == appearance.paintArgb &&
      other.appearance.glassArgb == appearance.glassArgb &&
      other.appearance.lampArgb == appearance.lampArgb;

  @override
  int get hashCode => Object.hash(
    displayName,
    dimensions.length,
    dimensions.width,
    dimensions.height,
    dimensions.wheelbase,
    appearance.paintArgb,
    appearance.glassArgb,
    appearance.lampArgb,
  );
}
