# App settings

설정 changes only what the app shows and how it behaves. There are no
vehicle controls (steering, acceleration, braking, engagement), no safety
parameters, no kovapilot developer switches (for example
`ENABLE_CANFD_LONGITUDINAL_STAGING`), and the app never writes vehicle
Params. Vehicle settings through a paired gateway stay locked until the
pairing/allowlist work exists (existing "차량 설정 (gateway)" section).

## Items

| Group | Setting | Values (default) |
| --- | --- | --- |
| 주행 화면 | 시점 | 뒤 (chase) · 위 (topDown) · 운전석 (driver) |
| | 도로 테마 | 맑음 (clear) · 흐림 (overcast) |
| | 속도 단위 | km/h · mph |
| | 앱 테마 | 시스템 · 밝게 · 어둡게 (어둡게) |
| | 화면 밝기 | 40–100 % (100 %), dims the road view |
| 표시 항목 | 차선 · 주변 차량 · 경로 · 배경 · HUD 수치 | on |
| 데모 | 데모 모드 | on; ignored while a gateway is connected |
| | 데모 경로 | 도심 · 고속도로 (도심) |
| 연결 장치 주소 | Telemetry WebSocket / Camera signaling | `ws://comma.local:8082/v1/telemetry`, `http://comma.local:8082/v1/stream` |
| 차량 모델 | select / preview / delete / 파일 가져오기 | `khronos-toy-car` |
| | GLB 3D 모델 겹치기 (실험) | off |

Addresses are saved only if `LocalEndpointPolicy` accepts them (loopback,
`.local`, private IPv4, link-local / unique-local IPv6 literals). Public
hosts are refused with "KovaLink는 로컬·사설 네트워크 gateway에만
연결합니다." The connect screen starts from the saved addresses.

- 화질 (`renderQuality`): 자동 (default; GPU where the device has it, falls
  back to software if the GPU view cannot start or averages over 70 ms per
  update for 90 updates) / 고품질 (always GPU when available) / 절약
  (software renderer).
- 도로 테마 (`sceneTheme`) also offers 노을, 밤 and 비.

## Storage

- `AppSettings` (`lib/src/settings/app_settings.dart`) is serialized as JSON
  (`schemaVersion: 1`) to `<application support>/kovalink_settings.json`
  (`path_provider`). Writes go to `…json.tmp` and are renamed.
- Reading is tolerant per field: an unknown or invalid value falls back to
  that field's default; stored addresses are re-checked against the
  local-only policy; invalid model ids are dropped.
- If storage fails, the app keeps working with in-memory settings and shows
  the problem in 설정.

## Packages

- `path_provider` (flutter.dev, BSD-3-Clause): app support directory.
- `file_picker` (MIT, incl. `android_file_picker` MIT): system document
  picker for `.kovamodel` import. The file size is checked before reading.
