# KovaLink local protocol draft

KovaLink connects only to loopback, `.local`, private IPv4, link-local IPv6, or
unique-local IPv6 endpoints. Public relay and comma cloud connectivity are out
of scope. IPv6 ranges apply only to bracketed IPv6 literals and IPv4 ranges only
to canonical dotted-decimal addresses; other hostnames must be `localhost` or
end in `.local`.

Plain `ws://` is allowed for first-party local development only. A paired
production gateway should use `wss://`; the app still applies the private-host
policy before opening either transport.

## Telemetry transport

The prototype accepts JSON objects over a local WebSocket. This makes the first
gateway easy to inspect. A binary protobuf transport can replace JSON after the
field contract stabilizes.

```json
{
  "monotonicTimeNanos": 123456789,
  "speedMps": 25.2,
  "setSpeedMps": 27.8,
  "steeringAngleDegrees": -1.5,
  "engaged": true,
  "gear": "drive",
  "leftBlinker": false,
  "rightBlinker": true,
  "brakeActive": false,
  "speedLimitKph": 100,
  "tbt": {
    "maneuver": "turnRight",
    "distanceMeters": 420,
    "roadName": "서울대학로 교차로",
    "nextManeuver": "turnLeft",
    "nextDistanceMeters": 1250,
    "remainingDistanceMeters": 31700,
    "remainingSeconds": 3600
  },
  "plannedPath": [{"x": 0, "y": 0, "z": 0}, {"x": 10, "y": 0.2, "z": 0}],
  "leftLane": [{"x": 0, "y": 1.85}],
  "rightLane": [{"x": 0, "y": -1.85}],
  "objects": [
    {
      "distanceMeters": 38,
      "leftMeters": 0.1,
      "relativeSpeedMps": -0.8,
      "kind": "vehicle"
    }
  ],
  "cameraProjection": {
    "matrix3x4": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0],
    "sourceWidth": 1928,
    "sourceHeight": 1208
  }
}
```

Coordinates use the vehicle frame: `x` is forward and `y` is left, in meters.
The app uses the monotonic timestamp for future camera-overlay alignment.
`gear`, blinkers, brake state, speed limit, and TBT are display-only typed
state. They must be derived from existing cereal/navigation state; KovaLink
never sends vehicle controls in response.
`cameraProjection.matrix3x4` maps `[x, y, z, 1]` vehicle-frame points to
homogeneous source-image pixels. The gateway derives it from the selected
camera intrinsics and current `extrinsicsCalibration`. KovaLink refuses to draw
AR geometry over video when this calibration is absent.

## Camera signaling

The app creates a receive-only WebRTC offer and posts it to the authenticated
local gateway. The gateway may proxy this request to kovapilot's loopback-only
`webrtcd` endpoint. KovaLink never requires `webrtcd` to listen directly on the
vehicle network.

```json
{
  "sdp": "...",
  "cameras": ["road"],
  "enabled": true,
  "bridge_services_in": [],
  "bridge_services_out": [],
  "raw": false
}
```

The app renders the decoded video and semantic overlay locally. Stopping the
view closes the peer connection; the gateway is responsible for returning the
vehicle-side livestream processes to idle.

## Gateway boundaries

- Subscribe only to selected cereal services; never forward raw CAN by default.
- Downsample scene data to 10–20 Hz.
- Require pairing and an allowlist before accepting setting writes.
- Treat a WebSocket connection as unauthenticated until a future pairing
  handshake completes; connecting alone never unlocks settings.
- Never expose VIN, dongle ID, Wi-Fi credentials, SSH material, or private URLs.
- Never expose safety parameters, cloud privacy flags, diagnostic writes, or
  vehicle actuation through the settings API.
- Start camera streaming only while a client is actively viewing it.

## Update policy

- Publish vehicle dynamics at 10–20 Hz using a monotonic timestamp.
- Publish TBT only when its value changes or in the next normal scene frame.
- Blink timing is rendered locally from the monotonic timestamp so network
  jitter does not make the indicator animation irregular.
- Omit unavailable fields instead of inventing a value. The UI renders a safe
  unknown/standby state.
