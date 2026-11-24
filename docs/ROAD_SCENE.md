# Road scene, demo and HUD

How KovaLink turns typed `RoadScene` frames into the driving screen. All
values are display-only; nothing here sends anything to the vehicle.

## Coordinate frame and units

- Scene frame: `x` forward, `y` left, `z` up, meters. Origin on the ground
  at the **ego front bumper** center, so `TrackedObject.distanceMeters` is
  the gap to the object's rear. The ego body occupies `x ∈ [-length, 0]`.
- Speeds in m/s on the wire; the HUD converts to km/h or mph
  (`SpeedUnit`). Distances stay metric (navigation sends meters).
- The vehicle model pack (GLB) keeps its own frame (`RH_Y_UP_Z_FORWARD`,
  origin between the rear wheels); see `VEHICLE_MODEL_PACK.md`.

## GPU renderer (`lib/src/gpu_scene/`, default on phones)

Real 3D on Filament through the vendored thermion 0.7 (Apache-2.0). The
software renderer below stays as the 절약 path and for tests.

- `RoadWorldGlb` builds the ego-relative world for each frame as a GLB:
  asphalt with tire tracks and seams (vertex-color noise scrolling with the
  odometer), lane paint (same dash phase as the software path), red edge
  bands, shoulders, guardrails (highway) or curbs (city), grass, soft
  low-poly trees, city blocks with window grids (lit at night), street
  lamps and the path ribbon (unlit, blended, teal → blue → violet, tinted
  amber/red by the lead tone, with an engage light sweep).
- `VehicleGpuGlb` turns the built-in vehicle/figure builders into GLBs with
  crease-angle smooth normals, PBR materials (clearcoat paint, reflective
  see-through glass, emissive lamps) and wheel pivots. Imported packs keep
  their own GLB materials; `GlbBounds` fits them by the manifest body node
  and hides `excludeNodes` and staging props.
- `GpuRoadRenderer` keeps one asset per road user (pooled), sets paint,
  lamp emission, wheel spin (speed / radius) and front-wheel steer
  (steering angle / 15.5), PCSS sun shadows + screen-space contact shadows,
  SAO, bloom, fog, MSAA + TAA and PBR-Neutral tone mapping. Lights: sun,
  ego headlights (focused spots), tail/brake glow (spots aimed back onto
  the road), street lamps, oncoming headlights.
- `SceneLook` (맑음/흐림/노을/밤/비): procedural sky (also baked into
  `assets/environments/*_ibl.ktx`, `*_skybox.ktx` by
  `tool/gpu/make_environments.sh`, Filament cmgen, CC0 output), exposure
  solved so the horizon lands at a target value, fog colour from the sky,
  headlight/lamp power given as on-screen levels. Rain = wet glossy
  translucent asphalt with mirrored vehicles/lamps below (puddle
  reflections) plus a rain overlay.
- Camera work comes from `SceneDirector` (shared with the software path):
  speed-dependent chase height/FOV, roll into announced turns, lead tone,
  engage sweep, blind-spot marks (`SceneMarkersPainter`).
- Worker captures: `tool/gpu/headless_gpu.dart` runs the same renderer on
  Mesa llvmpipe through an EGL surfaceless display; captures inject the
  frame with `RoadViewScreen.gpuSurfaceBuilder`
  (`tool/screenshots/gpu_capture_test.dart`, `KOVA_VIDEO=1` for the 10 s clip).

## Software renderer (`lib/src/features/road_view/scene3d/`, 절약)

`RoadWorldPainter` is a small software 3D pipeline drawn with Canvas, so
the same image renders on every platform and in tests:

- `SceneCamera` (`scene_camera.dart`): pitch-only pinhole camera with
  near-plane clipping and back-face tests.
  - `chase` (default): solved from screen targets (ego width share,
    horizon height, ego contact height) so portrait phones and landscape
    mounts get a similar composition; 9 m behind the rear bumper.
  - `topDown`: orthographic, metric scale kept.
  - `driver`: eye 42 % of the body length behind the front bumper,
    0.37 m left, 1.3 m up; only the hood is drawn.
- `ScenePalette` (`scene_palette.dart`): colors and exponential fog for
  `SceneTheme.clear` (맑음) / `overcast` (흐림) × `RoadType`
  (`highway` → grass and low-poly trees, `city` → buildings).
- Drawing order: sky/ground → shoulders, asphalt, seams, red edge bands →
  lane lines (color, style, confidence) → rainbow path ribbon (cyan → blue
  → violet, one soft-edged outline with a screen-space gradient, fades
  ahead, stops before the lead) → brake light pool →
  scenery and objects far-to-near → ego → lead distance bubble.
- Lead: `isLead` from the gateway, else the nearest vehicle within ±1.5 m
  of the planned path. Lead is blue with a `34.8 m` bubble, others are
  white and fade with fog. Cones, pedestrians and cyclists have their own
  shapes.
- Vehicles are triangle meshes (`vehicle_mesh_painter.dart`): per-vertex
  projection, screen-space back-face culling, painter's sort per triangle
  (decals biased forward), Gouraud lighting (sun, sky/ground ambient,
  viewer fill, Blinn-Phong highlight, Fresnel sky reflection), fog, lamp
  emission with glow, two-layer blurred contact shadow. One
  `drawVertices` per vehicle; level of detail by on-screen length.
- Ego: the selected pack's GLB levels (read in a background isolate), or
  the built-in KovaLink SUV in the pack's paint. Brake → lit lamp bar,
  corner lamps and stop lamp + glow + small red road glow; blinkers pulse
  from `monotonicTimeNanos` (0.5 s).
- Other vehicles: built-in SUV/sedan (by track id), trucks as a box truck,
  in the palette's lead/other colors. Size = reported `length/width/
  heightMeters`, else the model's real size (cars 1.45–1.69 m tall, truck
  9 × 2.5 × 3.2 m). Yawed along the planned path.
- `SceneLayers`: lanes / objects / path / scenery toggles (설정 → 표시 항목).
- AR camera overlay mode still uses `RoadScenePainter` with the gateway's
  `cameraProjection`.

## Road-scene fields used by the screen

All optional; older frames keep working.

| Field | Use |
| --- | --- |
| `laneLines[]` `{points, probability, color white/yellow/blue, style solid/dashed/doubleSolid}` | Lane lines. Without it, `leftLane`/`rightLane` are drawn as solid white |
| `roadEdges[]` (point lists) | Road width, shoulders, red edge bands |
| `roadType` `highway`/`city` | Scenery choice |
| `odometerMeters` | Scrolls dashes, seams and scenery smoothly |
| `objects[]` `id`, `kind` (+`truck`, `cyclist`, `trafficCone`), `length/width/heightMeters`, `isLead`, `brakeLights` | Object boxes |
| `roadName` | Info card header |
| `trafficSignal` `{state red/yellow/green, leftArrow, remainingSeconds, distanceMeters}` | Top-center pill |
| `roadAlerts[]` `{kind speedCamera/sectionCamera/tollgate/schoolZone, distanceMeters, speedLimitKph}` | Info card rows |
| `laneGuidance[]` `{directions[], recommended}` | Bottom lane pill |
| `tbt` (existing) | Turn row, green turn sign (city, ≤ 1 km), destination |

See `PROTOCOL.md` for the JSON example.

## HUD (`lib/src/features/road_view/hud/drive_hud.dart`)

Light glass pills (`LiquidGlass`): speed + unit + P R N D and assist /
set-speed pills (top-left), blinkers + traffic light countdown
(top-center), speed limit sign + route info card (top-right), green turn
sign (city), lane guidance (bottom-center), import / connect / settings
buttons (bottom-right, `KovaLinkHome`). Narrow screens (< 680 dp) stack
the center pill and cards lower. `showNumbers` (설정 → HUD 수치) hides the
numeric cards but keeps blinkers.

## Demo drive (`lib/src/services/demo_drive_scenario.dart`)

Network-free, deterministic: a frame is a pure function of
`(route, seed, elapsed)`; the loop is 90 s. The seed only changes
background traffic and small jitter.

- `city` (default): red-light stop → start → right curve with a cone work
  zone → lead approach and brake → left lane change → left-turn approach
  with lane guidance and signal → stop.
- `highway`: 86–100 km/h cruise → left curve → lead approach → overtaking
  lane change → new lead at 34.8 m; speed camera, tollgate, destination.

`GatewayController.startDemo({route, seed})` advances exactly 50 ms per
tick; `stopDemo()` shows `RoadScene.idle`. 설정 → 데모 turns it on/off and
never interrupts a live gateway session.

## Screenshots

`KOVA_SHOT_DIR=out flutter test tool/screenshots` renders the scene and full
screens headlessly (uses a host CJK font if present).

GPU captures (worker only, needs `build/native_assets/linux/libthermion_dart.so`
from a previous `flutter test` and Mesa EGL):

    KOVA_SHOT_DIR=out flutter test tool/screenshots/gpu_capture_test.dart
    KOVA_VIDEO=1 KOVA_SHOT_DIR=out flutter test tool/screenshots/gpu_capture_test.dart
    ffmpeg -framerate 24 -i out/video_frames/f_%04d.png -c:v libx264 -crf 22 -pix_fmt yuv420p demo.mp4
