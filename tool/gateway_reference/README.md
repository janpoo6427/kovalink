# 도로 장면 송신 변환 제안 (비배포)

이 폴더는 앱에 포함되지 않는 순수 Python 예시다. 실제 게이트웨이, 차량 제어, 인증 및 구독 설정을 변경하지 않는다. 대상은 `kovapilot master-jh`의 `bccedd3ab`(정차 중 종방향 설정 지원 기준)과 고정 `opendbc_repo`의 `11cc887d`(RadarData 스키마 기준)이다.

## 확인한 채널과 필드

- `cereal/log.capnp`의 Event union 현대 채널은 **`radarTracks :Car.RadarData`**이고, `services.py`의 송신 주기는 20 Hz다. `radard.py`도 이를 구독한다. `opendbc/car/car.capnp`의 `RadarData.points`에는 `trackId`, `dRel`, `yRel`, `vRel`이 있다. `liveTracksDEPRECATED`는 별도의 폐기된 **목록** union이고 이 버전의 활성 `liveTracks` 서비스가 아니다. 폐기된 목록을 `.points` 구조로 해석하지 않는다. `liveTracks.points`가 실제 존재하는 다른 포크에서만 명시적으로 해당 payload를 `tracks=`로 넘긴다.
- 이 버전의 `radarState`에는 `leadOne`/`leadTwo`와 `present`만 있다. 선택적 인접·끼어들기 목록과 `status`는 다른 스키마와의 호환용이고, 빠진 데이터를 만들어 내지 않는다. `radarState`의 lead가 모두 레이더와 매칭된 것은 아니다. `source=radarState`는 서비스 이름이다.
- `modelV2.laneLines/laneLineProbs`, `roadEdges/roadEdgeStds`, `position`, `leadsV3`, `carState`의 사각지대 플래그가 대상이다. 모델 y만 부호 반전한다. 모델 z는 높이를 추측하지 않고 지면 0으로 투영한다. **기본 모델 전방 보정은 0m**이다. 대상 `radard.py`는 자체 모델-레이더 정렬에 1.52m를 쓰지만 모든 장치의 기하학적 범퍼 보정으로 확인된 값은 아니다. 생산 송신기에서 교정된 모델-표시 원점 차이만 지정한다. 레이더 `dRel`, `yRel`은 다시 이동·반전하지 않는다.
- 원시 레이더 점이 실제 제공되는지, 시야 범위, 차량·보행자 구별은 차종/인터페이스에 따라 다르다. `kind=vehicle`은 원시 점의 검증된 물체 분류가 아니라 앱의 교통 객체 마커다. 사각지대 **플래그만으로** 차량 객체를 생성하지 않는다. 실차 송신·재생 미검증.

## 송신기 소유자가 통합할 때

1. `openpilot/kovapilot/gateway/telemetry.py`의 기존 구독에 `radarState`, `radarTracks`를 추가한다. 관측 전용이며 제어 및 설정 쓰기 경로와 분리한다. 레이더 서비스가 없는 차에서도 `carState` 기반 프레임을 계속 보낸다.
2. 기존 방식대로 신선하고 유효한 자차 상태를 확인한 다음, 선택 서비스별 `sm.valid[service]`와 `age_s=(now_ns-sm.logMonoTime[service])/1e9`를 사용한다. 무효/미수신 메시지는 `None`으로 전달. 서버 스냅샷 생성 시각을 개별 입력의 수신 시각으로 대신 쓰지 않는다.
3. 기존 도로 키들을 먼저 만들었다면 마지막에 `scene.update(scene_fields(car=car, model=..., model_age_s=..., radar=..., radar_age_s=..., tracks=..., tracks_age_s=..., model_origin_forward_m=...))`를 적용한다. 이 함수는 도로 필드만 반환하고 나머지 차량 상태를 보존한다. 빈 프레임은 소멸 처리한다. 최신 모델 0.5초, 레이더 상태 1초, 원시 점 0.3초가 기준이다. 원시 점은 상대속도로 수신 지연을 보정한다. 같은 추적 번호를 우선 합치고, 번호 없는 후보만 근접 위치·속도로 합친다. 반대 방향 차를 정지물로 오인하지 않도록 상대속도를 절댓값으로 바꾸지 않는다.
4. 앱-송신기 쌍의 좌표축·원점 확인, 실제 서비스 타임스탬프 검사, 양쪽 차선/반대방향·합류·정지물 재생을 거쳐 승인된 게이트웨이 저장소에 별도 반영한다. 앱 설치만으로 이미 배포된 송신기가 새 데이터를 보내지는 않는다.

시험: 이 디렉터리에서 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v`. 표준 라이브러리의 구조체 대역을 사용하며 capnp 런타임 또는 기기는 필요하지 않다.
