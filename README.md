# KovaLink

KovaLink is a local-first Android and iOS companion app for kovapilot. The app
renders telemetry and road scenes on the phone so the comma device only has to
publish selected state.

## Current prototype

- 2.5D road world (software 3D on Canvas): chase / top-down / driver views,
  clear and overcast themes, typed lane lines, road edges, lead bubble,
  rainbow path, low-poly scenery
- Manifest-driven ego vehicle (size and paint from the model pack), optional
  native Filament GLB overlay
- Public vehicle model pack format (`.kovamodel`) with a safe validator and
  in-app import, list, preview and delete
- Light glass HUD: speed, gear, assist state, signals, speed limit, route
  card, turn sign, lane guidance
- Deterministic city/highway demo drive (no network)
- Persisted app settings (units, view, theme, layers, demo, local addresses)
- Liquid-glass driving UI with speed, gear, signals, speed limit, and TBT
- Versioned, replaceable vehicle model-pack format
- Typed road-scene model for path, lanes, tracked objects, and vehicle state
- Local WebSocket telemetry client
- On-demand road-camera WebRTC receiver using the existing kovapilot stream
- Camera-only and camera-plus-model overlay modes
- Connection policy that rejects public hosts
- Vehicle (gateway) settings stay locked until an authenticated gateway is connected
- Separate telemetry and video transports so video stays off when not viewed

No comma cloud service, Athena connection, route upload, raw CAN forwarding, or
vehicle actuation is implemented.

## Run

```sh
flutter pub get
flutter run
```

## Verify

```sh
flutter analyze
flutter test
```

## Architecture

```text
KovaLink mobile app
  Flutter UI + road renderer
    | local WebSocket (typed telemetry)
    | local WebRTC (future, on demand)
    v
kovapilot KovaLink gateway
  selected cereal fields, pairing, setting allowlist
```

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the telemetry contract and gateway
boundaries, [docs/ROAD_SCENE.md](docs/ROAD_SCENE.md) for the renderer, HUD and
demo, [docs/APP_SETTINGS.md](docs/APP_SETTINGS.md) for settings and storage,
[docs/VEHICLE_MODEL_PACK.md](docs/VEHICLE_MODEL_PACK.md) for the public vehicle
model pack format, and [docs/VEHICLE_MODELING_GUIDE.md](docs/VEHICLE_MODELING_GUIDE.md)
for making your own model in Blender.

Model pack tools: `dart run tool/kovamodel.dart pack <folder> <out.kovamodel>`
and `dart run tool/kovamodel.dart check <file.kovamodel>`. Headless screen
captures: `KOVA_SHOT_DIR=out flutter test tool/screenshots`.
