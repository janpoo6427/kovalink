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

## Renderer (`lib/src/features/road_view/scene3d/`)

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
  → violet, fades ahead, stops before the lead) → brake light pool →
  scenery and objects far-to-near → ego → lead distance bubble.
- Lead: `isLead` from the gateway, else the nearest vehicle within ±1.5 m
  of the planned path. Lead is blue with a `34.8 m` bubble, others are
  white and fade with fog. Cones, pedestrians and cyclists have their own
  shapes.
- Ego: built from the model pack's `dimensionsMeters` and `appearance`
  colors (tapered body, slanted rear glass, roof, wheels, gloss highlight,
  soft contact shadow). Brake → bright tail lamps + glow + red ground pool;
  blinkers pulse from `monotonicTimeNanos` (0.5 s).
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
