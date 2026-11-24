# Making a KovaLink vehicle model (Blender)

This guide builds a `.kovamodel` pack for your own car with Blender 3.6+ /
4.x. The format itself is specified in
[VEHICLE_MODEL_PACK.md](VEHICLE_MODEL_PACK.md); start from the reference pack
`assets/vehicles/kovalink_basic/` if you want a working example.

Only use geometry and textures you made yourself or that carry a clear
license allowing redistribution (for example CC0 or CC-BY). Write the
source and license in `LICENSE.md`. Do not include manufacturer logos
without permission.

## 1. Scene setup

1. Scene Properties → Units: Unit System **Metric**, Unit Scale **1.0**,
   Length **Meters**. One Blender unit = 1 m.
2. Blender is Z-up; glTF is Y-up. Model in Blender's natural frame:
   - car front points to Blender **−Y** (the exporter's "+Y Up" option turns
     Blender −Y into glTF +Z forward),
   - car right side points to Blender **+X**,
   - roof points to Blender **+Z**.
3. Place the origin (3D cursor at world origin) **on the ground, centered
   between the rear wheels**. Rear axle at Y = 0, front axle at
   Y = −wheelbase.
4. Measure your car (spec sheet): length, width without mirrors, height,
   wheelbase. Draw a reference box with these sizes to model against.

## 2. Modeling

- Keep the whole car ≤ 100k triangles (hard limit 200k). A clean low-poly
  body (2–20k) looks good at phone size.
- Separate objects for parts that move or light up, named exactly:
  `Body` (parent of everything), `Wheel_FL`, `Wheel_FR`, `Wheel_RL`,
  `Wheel_RR` (origin at the wheel center), `Turn_FL`, `Turn_RL`, `Turn_FR`,
  `Turn_RR`, `Brake_L`, `Brake_R`, `Brake_C`, `Reverse_L`, `Reverse_R`,
  optional `SteeringWheel`.
- Parent the parts to `Body` (Ctrl+P → Object, Keep Transform).
- Apply transforms on every object: Object → Apply → **All Transforms**
  (wheels: apply rotation and scale only, keep the location so the pivot
  stays at the wheel center).

## 3. Materials

Use Principled BSDF only. Name materials:

- `KL_BodyPaint` — car paint; the app may recolor it with `appearance.paintColor`.
- `KL_Glass` — windows.
- `KL_Tail`, `KL_Brake`, `KL_TurnLeft`, `KL_TurnRight`, `KL_Reverse` —
  lamps. Give them an Emission color; the app controls the strength.

Textures: PNG or JPEG, ≤ 2048 × 2048, ≤ 16 images. Pack them into the file
(File → External Data → Pack Resources).

## 4. Export

File → Export → glTF 2.0:

- Format: **glTF Binary (.glb)**
- Include: Selected Objects or Visible Objects; no cameras or lights
- Transform: **+Y Up** checked
- Data → Mesh: Apply Modifiers checked; UVs and Normals checked
- Data → Material: Export; Images: Automatic
- Compression (Draco): off
- Animation: off

Name the file `vehicle.glb`.

## 5. Manifest and license

Copy `assets/vehicles/kovalink_basic/vehicle.json` and change `id`
(lowercase, digits, hyphen), `displayName`, `author`, `license`,
`dimensionsMeters`, and `appearance.paintColor`. Keep
`coordinateSystem: RH_Y_UP_Z_FORWARD`, `origin: rearAxleGround`,
`scale: 1.0`. List the node and material names you actually created.

Write `LICENSE.md` with author, source of every asset, and the SPDX license.

## 6. Pack

```sh
cd my_pack
zip -X -9 ../my-car.kovamodel vehicle.json vehicle.glb LICENSE.md
```

Files must sit at the archive root (no folder inside the ZIP).

## 7. Checklist before import

- [ ] Units meters, scale 1.0, transforms applied
- [ ] Front is glTF +Z, up +Y, right +X; origin at ground between rear wheels
- [ ] Length/width/height/wheelbase in `vehicle.json` match the car (m)
- [ ] ≤ 100k triangles (≤ 200k hard), textures ≤ 2048 px, PNG/JPEG
- [ ] All textures embedded; no external file or URL references
- [ ] Node names `Body`, `Wheel_*`, `Turn_*`, `Brake_*`, `Reverse_*`
- [ ] Material names `KL_*` for paint, glass and lamps
- [ ] `vehicle.json`: `id`, `displayName`, `author`, `license` filled in
- [ ] `LICENSE.md` present; you have the right to share every part
- [ ] ZIP contains only `vehicle.json`, the GLB, `LICENSE*`, optional
      `README.md` / `preview.png`, no folders
- [ ] `.kovamodel` ≤ 32 MB

Then in the app: 설정 → 차량 모델 → 파일 가져오기. If the app refuses the
file, the message names the first rule that failed.
