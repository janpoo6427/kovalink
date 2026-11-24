# KovaLink

KovaLink is a local-first Android and iOS companion app for kovapilot. The app
renders telemetry and road scenes on the phone so the comma device only has to
publish selected state.

## Current prototype

- Tesla-inspired semantic road view with a native Filament GLB ego vehicle
- Liquid-glass driving UI with speed, gear, signals, speed limit, and TBT
- Versioned, replaceable vehicle model-pack format
- Typed road-scene model for path, lanes, tracked objects, and vehicle state
- Demo telemetry at 20 Hz for development without a vehicle
- Local WebSocket telemetry client
- On-demand road-camera WebRTC receiver using the existing kovapilot stream
- Camera-only and camera-plus-model overlay modes
- Connection policy that rejects public hosts
- Settings shell locked until an authenticated gateway is connected
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
boundaries, and [docs/VEHICLE_MODEL_PACK.md](docs/VEHICLE_MODEL_PACK.md) for the
replaceable GLB vehicle format.
