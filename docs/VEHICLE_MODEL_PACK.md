# KovaLink vehicle model pack v1

A model pack is one directory containing `vehicle.glb`, `vehicle.json`, and the
model's license. KovaLink uses glTF Binary 2.0 (`.glb`) because it keeps meshes,
PBR materials, and textures in one portable file supported on Android and iOS.

## Coordinate and authoring rules

- Right-handed coordinates: `+X` right, `+Y` up, `+Z` vehicle-forward.
- Author in meters at real scale and place the origin at ground level between
  the rear wheels.
- Apply/freeze object transforms before export.
- Keep the body below 100k triangles and textures at or below 2048 px for the
  default mobile quality tier.
- Provide named nodes for controllable parts. Names are case-sensitive.
- Brake, reverse, and turn-signal nodes should use emissive-capable materials.
- Do not include manufacturer logos unless the pack author has permission.

## Manifest

`vehicle.json` is versioned independently from the GLB. Required values are the
model identity, asset filename, physical dimensions, coordinate system, and
camera presets. Node bindings are optional; missing bindings use KovaLink's
screen-space light effects.

```json
{
  "schemaVersion": 1,
  "id": "example-vehicle",
  "displayName": "Example Vehicle",
  "asset": "vehicle.glb",
  "coordinateSystem": "RH_Y_UP_Z_FORWARD",
  "dimensionsMeters": {
    "length": 5.0,
    "width": 2.0,
    "height": 1.7,
    "wheelbase": 3.0
  },
  "nodes": {
    "body": "Body",
    "frontLeftWheel": "Wheel_FL",
    "frontRightWheel": "Wheel_FR",
    "steeringWheel": "SteeringWheel",
    "leftTurnSignals": ["Turn_FL", "Turn_RL"],
    "rightTurnSignals": ["Turn_FR", "Turn_RR"],
    "brakeLights": ["Brake_L", "Brake_R"],
    "reverseLights": ["Reverse_L", "Reverse_R"]
  },
  "cameras": {
    "park": {"position": [2.6, 1.5, 3.4], "target": [0, 0.45, 0]},
    "drive": {"position": [0, 1.2, 3.2], "target": [0, 0.35, 0]}
  }
}
```

## Runtime mapping

- `steeringAngleDegrees` rotates the two front wheel nodes, clamped to the
  model pack's future steering limit metadata.
- `leftBlinker` and `rightBlinker` pulse the respective emissive nodes using
  `monotonicTimeNanos`.
- `brakeActive` enables the brake emissive nodes and a road glow.
- `gear == reverse` enables reverse lights and draws the predicted reverse
  steering path.
- If a node is absent, the rest of the model remains valid.

The bundled Khronos Toy Car is CC0 and serves only as a renderer/reference
asset. A vehicle-specific pack can replace it without changing telemetry or UI
code.
