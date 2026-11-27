# KovaLink

KovaLink is a local-first Android and iOS companion app for
[KovaPilot](https://github.com/janpoo6427/kovapilot), built for research and
development. It renders telemetry and road scenes on the phone so the comma
device only has to publish selected state.

## Research use and safety

> [!WARNING]
> KovaLink is experimental software for research and development only. Use it
> with caution in controlled test environments. Keep your attention on driving
> and operate the app only while parked. Use this software at your own risk.
> To the extent permitted by applicable law, you accept full responsibility
> for your use and for any resulting accidents, injuries, or property damage.

## Features

- **Live dashboard:** speed, gear, driver-assistance state, turn signals, speed
  limits, and turn-by-turn guidance from available telemetry.
- **Road visualization:** a 2.5D scene with lanes, path, road edges, and tracked
  vehicles. Choose chase, top-down, or driver view with clear or overcast themes.
- **On-demand video:** receive the road camera over WebRTC and view it alone
  or with a road-scene overlay. The app uses separate transports for telemetry
  and video and requests video only when you open the camera view.
- **Device connection and settings:** connect over a private network, discover
  the device or enter its address, and manage supported settings through an
  authenticated KovaLink Gateway. The app's connection policy rejects public hosts.
- **Offline demo and customization:** play a repeatable city or highway drive
  without a network connection. Save display preferences and import, validate,
  preview, or remove `.kovamodel` vehicle packs, with an optional native Filament
  GLB overlay.

## Acknowledgments

The companion project, [KovaPilot](https://github.com/janpoo6427/kovapilot),
builds on [openpilot](https://github.com/commaai/openpilot) and draws on feature
development in [CarrotPilot](https://github.com/ajouatom/openpilot) and
[sunnypilot](https://github.com/sunnypilot/sunnypilot). We develop KovaLink with
sincere gratitude and respect for the developers, testers, and communities
behind all three projects.

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
    | local WebRTC (on-demand, receive-only road video)
    v
KovaPilot KovaLink Gateway
  selected cereal fields, pairing, setting allowlist
```

The app's connection to the device is limited to the gateway's telemetry,
camera, and approved device-management interfaces. This keeps raw CAN and
vehicle actuation outside the app's scope. The app uses the device gateway for
these features independently of comma cloud services, Athena, and route uploads.

See [docs/PROTOCOL.md](docs/PROTOCOL.md) for the telemetry contract and gateway
boundaries, [docs/ROAD_SCENE.md](docs/ROAD_SCENE.md) for the renderer, HUD and
demo, [docs/APP_SETTINGS.md](docs/APP_SETTINGS.md) for settings and storage,
[docs/VEHICLE_MODEL_PACK.md](docs/VEHICLE_MODEL_PACK.md) for the public vehicle
model pack format, and [docs/VEHICLE_MODELING_GUIDE.md](docs/VEHICLE_MODELING_GUIDE.md)
for making your own model in Blender.

Model pack tools: `dart run tool/kovamodel.dart pack <folder> <out.kovamodel>`
and `dart run tool/kovamodel.dart check <file.kovamodel>`. Headless screen
captures: `KOVA_SHOT_DIR=out flutter test tool/screenshots`.
