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

## Optional display fields

Newer gateways may add these typed, display-only fields. Every field is
optional; KovaLink draws a safe fallback when one is missing (see
[ROAD_SCENE.md](ROAD_SCENE.md) for how each is rendered).

```json
{
  "roadType": "highway",
  "roadName": "경부고속도로",
  "odometerMeters": 1234.5,
  "laneLines": [
    {
      "points": [{"x": 0, "y": 1.8}, {"x": 60, "y": 1.9}],
      "probability": 0.94,
      "color": "white",
      "style": "dashed"
    }
  ],
  "roadEdges": [[{"x": 0, "y": 6.4}, {"x": 60, "y": 6.5}]],
  "objects": [
    {
      "id": 2,
      "distanceMeters": 34.8,
      "leftMeters": 0.1,
      "relativeSpeedMps": -0.5,
      "kind": "vehicle",
      "lengthMeters": 4.6,
      "widthMeters": 1.85,
      "heightMeters": 1.45,
      "isLead": true,
      "brakeLights": false
    }
  ],
  "trafficSignal": {
    "state": "green",
    "leftArrow": true,
    "remainingSeconds": 24,
    "distanceMeters": 247
  },
  "roadAlerts": [
    {"kind": "speedCamera", "distanceMeters": 545, "speedLimitKph": 100},
    {"kind": "tollgate", "distanceMeters": 1100}
  ],
  "laneGuidance": [
    {"directions": ["left"], "recommended": true},
    {"directions": ["straight"]}
  ]
}
```

- `distanceMeters` of objects is the gap from the ego front bumper (scene
  origin) to the object's rear.
- `laneLines` supersedes `leftLane`/`rightLane`; without it the legacy pair
  is drawn as solid white lines.
- `color`: `white`, `yellow`, `blue`; `style`: `solid`, `dashed`,
  `doubleSolid`. `kind`: `vehicle`, `truck`, `pedestrian`, `cyclist`,
  `trafficCone`, `unknown`. Unknown enum names map to `unknown`.
- Signals, alerts and lane guidance must come from existing navigation
  state; KovaLink never answers them with controls.

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

## Settings HTTP (kovapilot `kova_params`)

KovaLink reads and changes kovapilot user settings through the gateway's JSON
HTTP API on the same local origin as telemetry. The app stores only the
origin (`settingsEndpoint`, default `http://comma.local:8082`); a path, query,
fragment or user-info in that address is refused. The same local-only host
policy applies.

The setting list, groups, order, translations, constraints and apply policy
all come from the document. The app does not hard-code any of them.

### `GET /v1/health`

```json
{"status": "ok", "schemaVersion": 1, "bindScope": "loopback", "authentication": "localProcessOnly"}
```

KovaLink refuses a gateway whose `schemaVersion` major is not 1.

### `GET /v1/kova-params`

`200` returns the catalog merged with the current state:

```json
{
  "schemaVersion": 1,
  "defaultLocale": "ko",
  "locales": ["ko", "en"],
  "revision": 3,
  "device": {"offroad": true},
  "groups": [
    {"id": "steering", "order": 100,
     "title": {"ko": "조향", "en": "Steering"},
     "description": {"ko": "…", "en": "…"}}
  ],
  "settings": [
    {
      "key": "steering.always_on", "groupId": "steering", "order": 100,
      "type": "boolean", "defaultValue": false, "value": true,
      "title": {"ko": "항시 조향", "en": "Always-on steering"},
      "description": {"ko": "…", "en": "…"},
      "access": "readWrite", "risk": "control", "applyPolicy": "offroad",
      "availability": "pendingConsumer", "applyStatus": "pendingConsumer",
      "requiredCapabilities": ["alwaysSteering"]
    }
  ]
}
```

- `type`: `boolean`, `integer`, `number`, `string`, `enum`.
- `integer`/`number` may add `minimum`, `maximum`, `step` and a localized
  `unit`. `enum` has `options` (strings or integers, matched with the exact
  JSON type) and may add localized `optionTitles` keyed by the option text.
- `access`: `readOnly` | `readWrite`. `applyPolicy`: `immediate` (used right
  away), `offroad` (may only change while the device is offroad) or `restart`
  (used after openpilot restarts). `availability`/`applyStatus`: `available`,
  `pendingConsumer` (value is stored but nothing uses it yet), `unsupported`.
- `device.offroad` is read by the gateway from the device's own `IsOffroad`.
  It is informational; the gateway enforces the policy on update.
- `503 kova_params_unavailable`: stored state failed validation.

KovaLink parsing rules:

- Unknown fields are ignored. A minor version (`"1.4"`) is accepted; any
  other major `schemaVersion` closes the document (nothing is drawn).
- Text is shown in Korean, then English, then `defaultLocale`.
- Widgets: `boolean` → switch; ranged `integer`/`number` → slider plus number
  input; unranged numbers → number input; `enum` → pick sheet; `string`,
  `readOnly`, an unknown `type`/`access`/`applyPolicy`, or a current value that
  does not fit its type → read-only. `hidden: true` or `visibility: "hidden"`
  settings are not drawn (forward-compatible; the gateway does not emit these
  yet).
- Settings whose `groupId` is unknown are drawn in a trailing "기타" group.

### `POST /v1/kova-params/update`

Request body has exactly these fields:

```json
{"key": "steering.always_on", "value": true, "expectedRevision": 3}
```

| Status | `error.code` | Meaning | KovaLink |
|---|---|---|---|
| 200 | — | stored; body is the new document (`revision` + 1) | value confirmed |
| 400 | `invalid_request` | wrong field set or field types | "요청 형식" reason |
| 400 | `invalid_json` | body is not JSON | "요청 형식" reason |
| 400 | `invalid_value` | unknown key, wrong type or out of range | reason by message |
| 403 | `update_forbidden` | read-only, or `offroad` setting while onroad | reason by message |
| 409 | `revision_conflict` | `expectedRevision` is stale | re-read, show current value, ask again |
| 413 | — | body over 16 KiB (plain text) | failure |

Errors are `{"error": {"code": "…", "message": "…"}}`. KovaLink shows a
short Korean reason derived from the code (and, for `update_forbidden` /
`invalid_value`, from the message keywords `offroad`, `read-only`,
`unknown setting`, `out of range`); it never shows the raw message.

KovaLink write rules:

- A change is drawn as "보내는 중" and the confirmed value is replaced only by
  a `200` document. A timeout or transport failure is never a success: the
  app re-reads the document and shows whatever the device holds (the device
  may have stored the value after the app gave up).
- While the document says `device.offroad == false`, `offroad` and `restart`
  settings are locked in the app. (The gateway itself rejects only `offroad`
  settings onroad.)
- `risk: control` settings ask for confirmation first.
- Writes are locked while the connection is stale (last read failed or older
  than 45 s).

### Write lock before pairing (decision pending)

The gateway has no pairing, TLS or credential yet and binds to `127.0.0.1`
only. Until pairing exists KovaLink sends writes only when the settings
address is loopback (`127.0.0.1`, `::1`, `localhost`), i.e. a development
connection on the same machine. Every LAN address (`.local`, private IPv4,
link-local/ULA IPv6) is read-only. A future paired session may unlock LAN
writes; `GatewayController.gatewayAuthenticated` and `canEditSettings`
(telemetry socket) are unchanged and do not affect this lock.

### End-to-end test

`test/kovapilot_gateway_e2e_test.dart` drives a real gateway process through
`tool/e2e/kovapilot_gateway_hook.sh` (container with `--network host`, an
isolated `PARAMS_ROOT`). It is skipped unless `KOVA_E2E_GATEWAY_HOOK` is set.

## Git maintenance HTTP (kovapilot version screen)

Contract: kovapilot `docs/kovapilot/KOVALINK_GATEWAY.md` at
`master-jh@7cc3b3280`. Client: `lib/src/kovapilot_git/`; screen:
설정 → kovapilot → kovapilot 버전 (`/settings/kovapilot/version`).

| Request | Answer |
| --- | --- |
| `GET /v1/git/status` | `{branch\|null, head, upstream\|null, dirty, updaterState\|null, mutationEnabled: false}` |
| `GET /v1/git/branches` | `{branches: [{name, commit}]}` (fetched `origin/*` refs, no `origin/HEAD`) |
| `GET /v1/git/log?limit=1..100&cursor=0..10000` | `{entries: [{commit, parents, authorTime, subject}], nextCursor\|null}` (HEAD history) |
| `POST /v1/git/plan` `{operation: switch\|reset, branch, commit?}` | `{operation, branch, commit, branchHead, beforeHead, beforeBranch, dirty, requiresRestart, mutationEnabled: false, changedFileCount, planDigest}` |
| `POST /v1/git/apply` | `403 git_mutation_disabled` |

- A switch sends no commit; a reset sends a full 40-character SHA that must
  be in the chosen origin branch's history. Short SHAs and out-of-range
  pages are refused in the app before sending.
- Errors: `400 invalid_git_request`, `503 git_busy` (one inspection at a time;
  the app reads status, branches and log one after another),
  `503 git_unavailable`, `403 local_client_required`. Each is one plain line on
  screen; the gateway's message is never shown.
- Every switch/reset is a preview. 적용 is drawn but off with its reason
  ("콤마에서 아직 바꾸기를 허용하지 않아요."); the app never sends
  `/v1/git/apply` (`KovaGitClient.apply` exists only for the 403 test).

### Loopback-only gateway (`403 local_client_required`)

The gateway binds `127.0.0.1:8082` and refuses any request whose peer is not
loopback, that carries an `Origin` header, or whose `Host` is not
`localhost`/`127.0.0.1`/`[::1]`. A phone on Wi-Fi therefore cannot use it
yet. When some proxy or a future LAN bind still answers with this 403, the
app says "콤마를 찾았지만 아직 휴대폰 연결을 허용하지 않아요" — in 자동 연결
(`ProbeOutcome.localOnly`, never "콤마가 아니에요"), the settings client and
the version screen. Authenticated LAN access is a later gateway step.

### End-to-end test

`test/kovapilot_git_e2e_test.dart` runs kovapilot's own `create_app` and
`GitRepository` (no kovapilot change) in the dev container through
`tool/e2e/kovapilot_git_gateway_hook.sh` and
`tool/e2e/git_gateway_fixture.py`, against a throwaway repository (4 origin
branches, 25 commits; dirty, updater text, hidden checkout and slow-git
switches). Skipped unless `KOVA_E2E_GIT_HOOK` is set.
