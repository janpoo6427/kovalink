# KovaLink vehicle model pack v1

A model pack describes the user's own vehicle for KovaLink's road view. It is
plain data: a glTF 2.0 binary (`.glb`), a JSON manifest, and a license. The
format is public so anyone can build a pack for their car, share it, and
import it in the app (설정 → 차량 모델 → 파일 가져오기).

Authoring walkthrough (Blender): [VEHICLE_MODELING_GUIDE.md](VEHICLE_MODELING_GUIDE.md).
Reference pack: `assets/vehicles/kovalink_basic/` (CC0, the built-in
KovaLink SUV exported by `dart run tool/make_builtin_vehicles.dart`; a test
checks the bundled GLB is byte-identical to the generator output).

## Package: `.kovamodel`

A `.kovamodel` file is a ZIP archive with these files **at the archive
root** (no folders):

| File | Required | Notes |
| --- | --- | --- |
| `vehicle.json` | yes | Manifest, UTF-8 JSON, ≤ 64 KB |
| `<asset>.glb` | yes | Exactly the file named by `asset`, one GLB only |
| `LICENSE`, `LICENSE.md` or `LICENSE.txt` | yes | UTF-8, ≤ 256 KB |
| `README.md` | no | UTF-8, ≤ 256 KB |
| `preview.png` | no | PNG ≤ 1 MB and ≤ 1024 px; shown in the model list |

Any other file (scripts, executables, extra GLBs, textures beside the GLB,
folders, hidden files) makes the pack invalid.

Archive limits enforced by the app (`SafeZipReader`):

- `.kovamodel` ≤ 32 MB, ≤ 16 entries, each entry ≤ 24 MB, total unpacked
  ≤ 32 MB.
- Compression: stored or deflate only. No encryption, ZIP64, split archives
  or symlinks.
- Entry names: plain file names only. `../`, absolute paths, `\`, drive
  letters, nested folders, control characters and duplicate names
  (case-insensitive) are rejected.
- Decompression bombs: an entry whose unpacked/packed ratio exceeds 100 is
  rejected from the header alone; inflation is also streamed with a hard cap
  equal to the declared size, so a lying header cannot expand further.
- Every entry's CRC-32 must match.

Create a pack from a folder, for example:

```sh
cd my_pack && zip -X -9 ../my-car.kovamodel vehicle.json vehicle.glb LICENSE.md
```

## Coordinate and authoring rules

- Right-handed coordinates: `+Y` up, `+Z` vehicle-forward, so `+X` is the
  vehicle's **left** side (`"coordinateSystem": "RH_Y_UP_Z_FORWARD"`). This
  is glTF's native frame ("+Z forward, −X right"). Earlier revisions of
  this page said "+X right"; that was wrong — a symmetric body is not
  affected, but left/right lamp nodes are.
- Meters at real scale (`"scale": 1.0`). If you must author in another unit,
  `scale` is the multiplier from GLB units to meters (0.001–1000).
- Origin: on the ground, centered between the rear wheels
  (`"origin": "rearAxleGround"`).
- Apply/freeze object transforms before export.
- Self-contained GLB: every buffer and texture must be embedded. Any `uri`
  on a buffer or image (http/https, relative file, or `data:`) is rejected.
  The app never downloads anything for a model.
- Limits: ≤ 100k triangles recommended (warning above), 200k hard limit;
  textures PNG/JPEG only, ≤ 2048 px per side, ≤ 16 images.
- Road renderer budget: **20,000 triangles per vehicle**. Above that the
  import shows a warning and the app draws a simplified copy (vertex
  clustering). Far vehicles always use two lower levels the app derives
  itself (≤ 1,600 and ≤ 360 triangles), so a pack ships only LOD0.
- Compressed geometry is refused with a reason: `KHR_draco_mesh_compression`,
  `EXT_meshopt_compression`, `KHR_meshopt_compression` (code
  `glb-compressed`) — export without Draco/meshopt. Sparse accessors are
  refused too (`glb-unsupported`). `KHR_mesh_quantization` (normalized
  integer positions/normals) is supported.
- `extensionsRequired` may only list: `KHR_materials_clearcoat`,
  `KHR_materials_emissive_strength`, `KHR_materials_ior`,
  `KHR_materials_sheen`, `KHR_materials_specular`,
  `KHR_materials_transmission`, `KHR_materials_unlit`,
  `KHR_materials_volume`, `KHR_mesh_quantization`, `KHR_texture_transform`.
  Optional extensions in `extensionsUsed` are allowed; unsupported ones are
  ignored by the renderer.
- Do not include manufacturer logos unless the pack author has permission.

glTF has no scripting; KovaLink reads the pack strictly as data and never
executes anything from it.

## Naming conventions

Nodes (case-sensitive; used for animation/lighting effects):

| Role | Convention | Manifest key |
| --- | --- | --- |
| Body root | `Body` | `nodes.body` |
| Wheels (optional) | `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR`, pivot at the wheel center | `nodes.frontLeftWheel` … `nodes.rearRightWheel` |
| Steering wheel (optional) | `SteeringWheel` | `nodes.steeringWheel` |
| Turn signals | `Turn_FL`, `Turn_RL` / `Turn_FR`, `Turn_RR` | `nodes.leftTurnSignals` / `nodes.rightTurnSignals` |
| Brake lights | `Brake_L`, `Brake_R`, `Brake_C` (high-mount) | `nodes.brakeLights` |
| Reverse lights | `Reverse_L`, `Reverse_R` | `nodes.reverseLights` |

Materials:

| Role | Convention | Manifest key |
| --- | --- | --- |
| Recolorable body paint | `KL_BodyPaint` | `materials.bodyPaint` |
| Glass | `KL_Glass` | `materials.glass` |
| Tail lights (always on, dim) | `KL_Tail` | `materials.tailLights` |
| Brake lights | `KL_Brake` | `materials.brakeLights` |
| Turn signals | `KL_TurnLeft`, `KL_TurnRight` | `materials.leftTurnSignals`, `materials.rightTurnSignals` |
| Reverse lights | `KL_Reverse` | `materials.reverseLights` |

Lamp materials should be emissive-capable (PBR + `emissiveFactor`). Names
listed in the manifest but missing from the GLB produce a warning and the
effect is skipped; the pack is still valid.

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "my-ioniq9",
  "displayName": "내 IONIQ 9",
  "author": "홍길동",
  "license": "CC-BY-4.0",
  "asset": "vehicle.glb",
  "coordinateSystem": "RH_Y_UP_Z_FORWARD",
  "origin": "rearAxleGround",
  "scale": 1.0,
  "dimensionsMeters": {
    "length": 5.06,
    "width": 1.98,
    "height": 1.79,
    "wheelbase": 3.13
  },
  "appearance": {
    "paintColor": "#545E6B",
    "glassColor": "#0D141C",
    "lampColor": "#B01D31"
  },
  "nodes": {
    "body": "Body",
    "frontLeftWheel": "Wheel_FL",
    "frontRightWheel": "Wheel_FR",
    "rearLeftWheel": "Wheel_RL",
    "rearRightWheel": "Wheel_RR",
    "steeringWheel": "SteeringWheel",
    "leftTurnSignals": ["Turn_FL", "Turn_RL"],
    "rightTurnSignals": ["Turn_FR", "Turn_RR"],
    "brakeLights": ["Brake_L", "Brake_R", "Brake_C"],
    "reverseLights": ["Reverse_L", "Reverse_R"]
  },
  "materials": {
    "bodyPaint": "KL_BodyPaint",
    "glass": "KL_Glass",
    "tailLights": "KL_Tail",
    "brakeLights": "KL_Brake",
    "leftTurnSignals": "KL_TurnLeft",
    "rightTurnSignals": "KL_TurnRight",
    "reverseLights": "KL_Reverse"
  },
  "cameras": {
    "park": {"position": [2.6, 1.5, 3.4], "target": [0, 0.45, 0]},
    "drive": {"position": [0, 1.2, 3.2], "target": [0, 0.35, 0]}
  }
}
```

Field rules (import validator `ModelPackValidator`):

| Field | Rule |
| --- | --- |
| `schemaVersion` | `1` |
| `id` | `^[a-z0-9][a-z0-9-]{1,47}$`, unique; built-in ids (`khronos-toy-car`, `kovalink-basic`) are reserved |
| `displayName` | 1–48 characters |
| `author` | required, ≤ 80 characters |
| `license` | required SPDX identifier (for example `CC0-1.0`, `CC-BY-4.0`), ≤ 64 characters |
| `asset` | plain `.glb` file name (`[A-Za-z0-9_-]+.glb`) |
| `coordinateSystem` | `RH_Y_UP_Z_FORWARD` |
| `origin` | `rearAxleGround` (default when omitted) |
| `scale` | 0.001–1000, default 1.0 |
| `dimensionsMeters` | length 2.5–7.5, width 1.2–2.8, height 0.9–3.5, wheelbase ≥ 1.5 and ≤ length − 0.3 |
| `appearance.*Color` | optional `#RRGGBB` / `#AARRGGBB` |
| `nodes`, `materials`, `cameras` | optional; see naming conventions |

Bundled packs inside the app may omit `author`, `license`, `origin` and
`scale` (older v1 manifests); the bundled loader then uses safe defaults.
If a bundled manifest is broken or its dimensions are implausible, the app
uses the built-in renderer with reference dimensions instead of failing.

## Runtime mapping

- The road view reads the pack's GLB itself (`GltfMeshReader`) and draws its
  triangles in the same 2.5D camera as the road (`VehicleMeshPainter`,
  `Canvas.drawVertices`), on every platform and in tests. Read: POSITION,
  NORMAL (computed when missing), TEXCOORD_n, uint8/16/32 indices,
  triangle lists/strips/fans, the node hierarchy (TRS or matrix),
  `baseColorFactor`, `metallicFactor`, `roughnessFactor`, `emissiveFactor`.
  A base color texture is optional: it is decoded at ≤ 256 px and baked
  into vertex colors. Lines/points are skipped.
- Size: the mesh is placed by `dimensionsMeters`, not by its own units.
  `length` sets one uniform scale (mirrors and wheels keep proportions);
  width or height more than 25 % off the declared value is scaled per axis.
  The rear-most point goes to the rear bumper, the lowest point to the road.
- Roles: `materials.*` names and `nodes.*` lamp lists give triangles a role
  (paint, glass, tail, brake, left/right turn, reverse). Without a binding
  the KovaLink standard names are recognized: `KL_BodyPaint`, `KL_Glass`,
  `KL_Tail`, `KL_Brake`, `KL_TurnLeft`, `KL_TurnRight`, `KL_Reverse`,
  `KL_Head`, `KL_Plate`, `KL_Tire`, `KL_Rim`, `KL_Trim`, `KL_Chrome`.
  `bodyPaint` takes the paint color; lamps light from the frame's state.
- Materials whose name ends in `_Decal` (and all lamp/plate materials) are
  drawn after the surface they sit on (put them 3–10 mm above it).
- `excludeNodes` (optional manifest list of node names) leaves out display
  stands, ground cloths and the like, with their children.
- If the GLB cannot be drawn, the app keeps the pack's size/paint on the
  built-in KovaLink SUV and shows why. On Android/iOS the thermion GLB
  overlay stays available as an experiment switch.
- `steeringAngleDegrees` rotates the two front wheel nodes, clamped to the
  model pack's future steering limit metadata.
- `leftBlinker` and `rightBlinker` pulse the respective emissive nodes using
  `monotonicTimeNanos`.
- `brakeActive` enables the brake emissive nodes and a road glow.
- `gear == reverse` enables reverse lights and draws the predicted reverse
  steering path.
- If a node is absent, the rest of the model remains valid.

## Import flow in the app

1. 설정 → 차량 모델 → 파일 가져오기 opens the system file picker
   (`.kovamodel`).
2. The validator checks archive safety, files, manifest, and GLB as above
   and shows the first rejection reason, or warnings for a valid pack.
3. A valid pack is copied to app storage
   (`<app support>/vehicle_models/<id>/`), replacing an older pack with the
   same id.
4. The model list offers select, preview (built-in renderer with the
   pack's size and paint, or `preview.png`) and delete.
5. If the selected pack later fails to load, the app returns to the
   built-in default model.

## Bundled packs and sources

- `assets/vehicles/kovalink_basic/` — KovaLink basic SUV (default model),
  self-made by the KovaLink project from code
  (`lib/src/vehicle_mesh/builtin_vehicles.dart`), CC0-1.0. Reference
  example of this format: named nodes (`Body`, `Wheel_*`, `Brake_L/R/C`,
  `Turn_FL/FR/RL/RR`, `Reverse_L/R`, `Tail`) and `KL_*` materials.
- `assets/vehicles/toy_car/` — Khronos glTF Sample Assets "ToyCar", model by
  Guido Odendahl, materials by Eric Chadwick, CC0-1.0. Renderer reference;
  exceeds the recommended triangle count (warning only; 91k triangles are
  drawn as a ≈17k simplified copy). Its display cloth node `Fabric` is
  excluded with `excludeNodes`.
