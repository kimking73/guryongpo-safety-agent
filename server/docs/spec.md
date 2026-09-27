> **저장소 안 위치 (2026-09-27 이관)** — 이 문서는 1주차 작업 폴더 기준으로 쓰였다. 경로는 아래처럼 읽는다.
> `db/schema.sql` → `db/init/01_schema.sql` · `db/seed.sql` → `02_seed.sql` · `seed_landslide` → `03` · `seed_knowledge` → `04` · `seed_shelters` → `05` · `seed_medical` → `06` ·
> `db/erd.*` → `db/erd.*` (저장소 루트) · `api/openapi.yaml` → `server/spec/openapi.yaml` · `mock/` → `server/mock/` · `tools/` → `server/tools/` ·
> 산사태 CSV → `server/data/` · `dt_config.txt` → `server/dt_config.txt` (gitignore).
> A2 이후 서버 구현은 `server/README.md`.

# 구룡가디언 — A1 DB 스키마 · API 명세 (v0.2)

> 목표: 전 팀이 공유할 데이터 구조와 통신 규약을 고정한다.
> 완료 기준: **B·C 검토 완료 + 목업 JSON 공유** → 아래 [7. 검토 체크리스트](#7-bc-검토-체크리스트)

| 산출물 | 파일 |
|---|---|
| ERD | `db/erd.png` (원본 `db/erd.mmd`) |
| DB 스키마 | `db/schema.sql` (테이블 31개 + 뷰 2개), `db/seed.sql` (데이터 출처 10 + 위험 판단 기준 30), `db/seed_landslide.sql` (산사태 취약지역 488곳), `db/seed_knowledge.sql` (행동요령 51 · 지원제도 9 · 긴급전화 20), `db/seed_shelters.sql` (구룡포 대피소 19), `db/seed_medical.sql` (포항 응급의료기관 5) |
| API 명세 (OpenAPI 초안) | `api/openapi.yaml` — https://editor.swagger.io 에 붙여넣으면 문서로 보임 |
| 목업 JSON | `mock/*.json`, `mock/*.geojson` (13개, 모두 명세 스키마로 자동 검증 통과) |
| 도구 | `tools/make_mocks.py` (목업 재생성), `tools/validate.py` (명세 ↔ 목업 검증), `tools/pohang_dt_water.py` (포항 DT 수위계 응답 변환), `tools/pohang_dt_air.py` (대기환경·자외선 응답 변환), `tools/kma_vilage.py` (기상청 동네예보 응답 변환), `tools/kma_warn_aws.py` (기상특보·AWS 바람 변환), `tools/kma_typhoon.py` (태풍 경로 변환·영향권 판단), `tools/landslide_zones.py` (산사태 취약지역 CSV → SQL·GeoJSON), `tools/seed_knowledge.py` (포항시 재난안전 페이지 → 행동요령·지원제도·긴급전화 SQL), `tools/geocode_shelters.py` (대피소 주소 → 좌표, 카카오 로컬 API), `tools/nmc_medical.py` (응급의료기관·실시간 병상), `tools/fetch_dt.py` (포항 DT·기상청 API 일괄 호출 → `mock/external/`, 키는 `dt_config.txt`) |

```bash
createdb guryong && psql guryong -f db/schema.sql -f db/seed.sql -f db/seed_landslide.sql -f db/seed_knowledge.sql -f db/seed_shelters.sql -f db/seed_medical.sql
cd tools && python3 validate.py          # 명세를 바꾸면 반드시 다시 실행
```

---

## 1. 테이블 설계

![ERD](db/erd.png)

| 타임라인 항목 | 테이블 |
|---|---|
| **관측값** | `stations`, `observations`(관측소×지표×시각, long format), `v_latest_observations`, `forecasts`, `weather_warnings`, `typhoon_tracks`, `data_sources`, `ingest_runs` |
| **위험 판정** | `risk_rules`(판단 기준·출처), `risk_assessments`(판정 결과 영역), `user_alerts`(사용자별 경고) |
| **사용자** | `users`(firebase_uid), `user_profiles`, `user_places`, `emergency_contacts`, `user_devices`(fcm_token, 마지막 위치) |
| **대피소·시설** | `shelters`, `medical_facilities`, `er_availability`(응급실 실시간 병상), `hazard_zones`(산사태·침수·해안 위험지역), `manholes` |
| **재난문자** | `disaster_messages` |
| 그 외 | 경로 `route_requests` · 지식 `action_guides`, `checklist_items`, `user_checklist_progress`, `support_programs`, `public_hotlines`(긴급전화) · 대화 `chat_sessions`, `chat_messages`, `agent_runs` · `emergency_events` |

## 2. 엔드포인트 (`/api/v1`)

| 엔드포인트 | 메서드 | 용도 | 목업 |
|---|---|---|---|
| `/health` | GET | 서버·DB·수집기·GraphHopper·Gemini 상태 | `health.json` |
| `/user` | POST · GET · PATCH · DELETE | 첫 실행 등록(uid 기준, 멱등) / 내 정보 / 인적사항 수정 / 탈퇴 | `user.json` |
| `/user/places`, `/user/places/{id}` | POST · PATCH · DELETE | 집·직장·자주 가는 곳·숙소 | (user.json 안) |
| `/user/contacts`, `/user/contacts/{id}` | POST · DELETE | 비상연락처 | (user.json 안) |
| `/user/checklist/{item_id}` | PUT · DELETE | 체크리스트 체크/해제 | – |
| `/device-token` | POST · DELETE | FCM 토큰 등록·해제 → `device_id` 발급 | `device-token.json` |
| `/dashboard` | GET | 맞춤 대시보드 (모드·위젯 순서·강조 레이어를 서버가 결정) | `dashboard.normal.json`, `dashboard.emergency.json` |
| `/dashboard/layers/{layer_id}` | GET | 지도 레이어 GeoJSON | `layer.shelters.geojson`, `layer.stations.geojson` |
| `/risk` | GET | 한 지점의 재난별 위험도 | `risk.json` |
| `/risk/areas`, `/risk/rules` | GET | 위험 영역 GeoJSON / 판단 기준표 | `risk-areas.geojson` |
| `/alerts` | GET | **폴링** — 새 경고 + 위치 보고 + 다음 폴링 간격 | `alerts.json` |
| `/alerts/{id}/read` | POST | 읽음 처리 | – |
| `/chat` | POST | 텍스트 질문 → Agent 답변 (session_id 생략 시 새 대화) | `chat.json` |
| `/chat/sessions`, `/chat/sessions/{id}` | GET | 대화 목록·내역 | – |
| `/voice` | POST | 녹음 업로드 → 서버가 STT → Agent → TTS | `voice.json` |
| `/voice/audio/{id}` | GET | TTS mp3 (`audio_url`) | – |
| `/route` | POST | 안전 대피 경로 | `route.json` |
| `/route/check` | POST | 이동 중 재검사 (30초 간격) → 필요 시 재탐색 | `route-check.json` |
| `/internal/simulate` | POST | **시연용** 재난 시나리오 주입 (힌남노 등) | – |

## 3. 목업 JSON 시나리오

모든 목업은 하나의 이야기로 이어진다 (장소·수치는 가상):
**2026-10-05 14:30, 포항시 호우경보 발효 중.** 사용자는 1958년생 어업인(선박 보유, 보행 제한)으로 구룡포항 근처에 있고, 집은 산사태 위험지역 안.

- `dashboard.normal.json` ↔ `dashboard.emergency.json`: 같은 사용자의 평상시/재난 모드 비교
- `alerts.json`: 집 → 산사태 경고, 현재 위치 → 침수 경고 (`reason` 에 왜 이 사람에게 보냈는지)
- `chat.json` / `voice.json`: "배 보러 부두에 가도 되나" → 가지 말고 대피하라는 답변 + 행동 단계·경로 카드·119 버튼 + 근거(grounding)
- `route.json` → `route-check.json`: 고령자 프로필 경로(맨홀 4개·급경사 2곳 회피) → 이동 중 새 침수로 재탐색

## 4. 위험도 표기 규약 (재난 종류 · 단계 · 좌표)

모든 API는 위험도를 **`RiskItem` 한 가지 형식**으로만 표기한다.

```json
{ "hazard": "flood", "level": "warning", "level_num": 3, "label": "침수 경보",
  "reason": "구룡포환승센터 지표면 수위계 침수심 230mm (기준 150mm) · 포항 DT 4단계(경보)",
  "location": { "lat": 35.9903, "lng": 129.5558 }, "area_id": 1022, "rule_id": 23,
  "observed_at": "2026-10-05T14:27:00+09:00" }
```

**재난 종류 `hazard`**

| 코드 | 이름 | 코드 | 이름 |
|---|---|---|---|
| `landslide` | 산사태 | `high_seas` | 풍랑 |
| `heavy_rain` | 호우 | `fine_dust` | 미세먼지(PM10) |
| `flood` | 침수 | `ultrafine_dust` | 초미세먼지(PM2.5) |
| `strong_wind` | 강풍 | `uv` | 자외선 |
| `typhoon` | 태풍 | | |

**단계 `level` / `level_num`** — 색상은 C 제안값, 검토 시 확정

| num | 코드 | 일반 재난 | 자외선 | 색 (제안) |
|---|---|---|---|---|
| 0 | `normal` | 정상 | 낮음 | 회색 `#9E9E9E` |
| 1 | `watch` | 관심 | 보통 | 파랑 `#1E88E5` |
| 2 | `advisory` | 주의보 | 높음 | 노랑 `#FBC02D` |
| 3 | `warning` | 경보 | 매우높음 | 주황 `#F57C00` |
| 4 | `critical` | 심각 | 위험 | 빨강 `#D32F2F` |

**좌표**
- 요청·일반 응답: `{ "lat": 위도, "lng": 경도 }` (WGS84)
- 지도 도형(GeoJSON): `[경도, 위도]` 순서 — **순서가 반대이므로 주의**
- DB: `geometry(..., 4326)`
- `/dashboard/layers`, `/risk/areas` 의 bbox: `minLng,minLat,maxLng,maxLat`

## 5. 인증 · 실시간 전달 · STT 방식

**인증 — Firebase 익명 로그인**
1. 앱: `FirebaseAuth.instance.signInAnonymously()` → `currentUser.getIdToken()`
2. 모든 요청: `Authorization: Bearer <idToken>` (만료 1시간, SDK가 자동 갱신)
3. 서버: `firebase_admin.auth.verify_id_token()` → `uid` → `users.firebase_uid`
4. 첫 실행 시 `POST /user` 한 번 (이미 있으면 200으로 그대로 반환)
5. 토큰 없이 되는 것: `/health`, `/risk*`, `/dashboard/layers/*`, `/voice/audio/*`

**실시간 전달 — FCM + 폴링**

| 앱 상태 | 방식 |
|---|---|
| 백그라운드/종료 | FCM 푸시. `notification` 에 제목·본문, `data` 에 `kind, alert_id, hazard, level, level_num, action` (전부 문자열, 스키마 `FcmAlertPayload`) |
| 포그라운드 | `GET /alerts?since=&device_id=&lat=&lng=` 폴링. 간격은 응답의 `next_poll_sec` (평상시 60초, 재난 모드 15초) |
| 경로 안내 중 | `POST /route/check` 30초 간격 |

같은 경고가 FCM과 폴링 양쪽으로 올 수 있으므로 앱은 `alert.id` 로 중복을 제거한다. 다음 폴링의 `since` 는 응답의 `server_time` 을 쓴다.

**STT — 서버에서 호출**
1. 앱: 녹음(m4a/webm/wav, 최대 30초) → `POST /voice` (multipart)
2. 서버: Google STT → LangGraph Agent → Google TTS → mp3 저장
3. 응답: `transcript`(사용자 말풍선) + `message`(답변) + `message.audio_url` (앱은 바로 재생)
4. 인식 실패 시 422 `STT_FAILED` → 앱이 "다시 말씀해 주세요" 안내
5. Google 키는 서버에만 둔다

## 5-1. 포항 디지털 트윈 센서 연동 (수위계 장비 실시간 수집 정보)

API: `GET https://genix.pohang-eum.kr/dpg/sensor/latest/sensorLevel?serviceKey=…` (`tools/fetch_dt.py` 로 호출 → `mock/external/pohang_dt_water_level.json`)
참고: `/water/rainDevices?id=5` (강우량계 장비 정보)는 이름·좌표·주소만 반환 — 수위계 응답과 중복이라 수집하지 않음. `id` 없으면 "id 파라미터가 빠져있습니다."

응답: `{"id":"1","status":"success","data":[ …센서 10개… ]}` — 원문은 `mock/external/pohang_dt_water_level.sample.json`

**센서 종류** (구룡포 10개, id 6 은 응답에 없음)

| sensorType | 뜻 | `stations.kind` | metric | 단위 | 개수 |
|---|---|---|---|---|---|
| `HOLE` | 스마트맨홀 (value 는 저장만, **판단은 level 만**) | `manhole` | `manhole_level` | mm | 3 |
| `ROAD` | 지표면 수위계 (도로 침수심) | `road_flood` | `flood_depth` | mm | 5 |
| `RIVER` | 하천 수위계 | `river_level` | `river_level` | mm | 1 |
| `RAIN` | 강우량계 (시간당 강우량) | `rain_gauge` | `rain_1h` | mm | 1 |

**등급 `level`** (문자열) → `observations.source_level` → 우리 단계

| 포항 DT | 1 정상 | 2 보통 | 3 주의 | 4 경보 | 5 위험 |
|---|---|---|---|---|---|
| 우리 `level` | `normal` (0) | `watch` (1) | `advisory` (2) | `warning` (3) | `critical` (4) |

5단계가 우리 위험 단계 5개와 1:1 로 맞음.

**필드 매핑**

| 응답 필드 | DB |
|---|---|
| `id` | `stations.external_id` (문자열) |
| `eui`, `sensorType` | `stations.meta` |
| `name`, `address` | `stations.name`, `stations.address` |
| `latitude`, `longitude` | `stations.geom` (Point, 4326) |
| `value` (문자열, mm) | `observations.value` |
| `level` (문자열) | `observations.source_level` |
| (시각 없음) | `observations.observed_at` = **수집 시각** (원천 측정 시각은 알 수 없음) |

**수집기 (A2)**
- `tools/pohang_dt_water.py`: `normalize(원문 문자열 또는 dict)` → `UPSERT_STATION_SQL`, `INSERT_OBSERVATION_SQL` 그대로 사용
- 응답 앞 `{` 누락 자동 보정, `status != "success"` 이면 예외, 모르는 sensorType 은 건너뛰고 `skipped` 로 반환
- **측정 시각을 알 수 없으므로** 약 1시간 주기 갱신을 놓치지 않게 **10분마다 수집**하고 스냅샷을 전부 저장 (센서 10개 × 하루 144회 ≈ 1,440행/일)
- 앱에는 `observed_at` 을 "측정 시각"이 아니라 **"14:27 수집"** 처럼 표기
- 갱신 지연 감지: 같은 센서 값이 3시간 넘게 한 번도 안 바뀌어도 정상일 수 있으므로, 대신 **API 호출 실패/`status` 오류가 30분 이상 이어지면** `/health` 에 `ingest.pohang_dt: degraded`

**판단 기준 (`risk_rules`)**
- 9번: ROAD 침수심 ≥ 150mm(15cm) → 침수 발생 (반경 150m)
- 21~24번: 맨홀·지표면·하천 수위계 등급 2/3/4/5 → 침수 보통/주의/경보/위험 (반경 100/150/300/500m)
- 25~28번: 강우량계 등급 2/3/4/5 → 강우 보통/주의/경보/위험
- 강우량계 `rain_1h`(시간당) 는 `RAIN_SUM_SQL` 로 3시간·12시간 누적을 근사해 호우특보 기준(3시간 60mm 등)에도 사용
  (지금, 1시간 전, 2시간 전 시점의 최근 스냅샷을 합산 — 갱신 분을 몰라도 동작, 매시 23분 갱신 가정 테스트에서 10+20+30=60mm 확인)
- 스마트맨홀은 GraphHopper 맨홀 회피에 **등급 3(주의) 이상일 때 가중치를 더 크게** 적용 (B 검토)

## 5-2. 포항 디지털 트윈 대기환경 · 자외선 연동

**API** (기본 주소 `https://genix.pohang-eum.kr/dpg`, 쿼리 `serviceKey` 필수 — 키는 `dt_config.txt`, 공유 금지)

| API | 경로 | 응답 (2026-09-26 확인) | 원문 |
|---|---|---|---|
| 대기환경 장비 목록 | `/atmosphere/devices` | 24대 — id, 좌표(문자열), 주소, `nickname`(설치 위치) | `mock/external/atmosphere_devices.json` |
| 대기환경 실시간 | `/atmosphere/devices/realtime` | 장비별 최신값 23대 (23번 없음) + **`logDateTime`** | `mock/external/atmosphere_realtime.json` |
| 자외선 실시간 | `/sensor/latest/uvIndex` | 구룡포 전역 값 1개 `{dateTime, uvIndex}` — 장비·좌표 없음 | `mock/external/uv_latest.json` |
| 자외선 장비 정보 | `/uv/devices?id=` | 유효한 id 확인 불가 → **사용 안 함** (자외선은 전역 값 1개만 사용) | – |

키 오류 시 형식이 다름: `{"rspns_rslt":{"rslt_cd":"40102","rslt_msg":"유효하지 않은 이용자 서비스 키"},"rspns_bdy":null}`
→ `fetch_dt.py` 는 `ERR`, 변환기는 `PohangDTError` 로 처리.
인코딩된 키(`%` 포함)는 한 번 디코딩 후 인코딩해야 함 (이중 인코딩 시 40102).

**필드 매핑**

| 응답 | DB |
|---|---|
| 장비 `id` | `stations.external_id = 'air_<id>'`, `kind = 'air'` |
| `nickname` / `name`, `firm` | `stations.name` / `stations.meta` |
| `pm10`, `pm25` | `observations` metric `pm10`, `pm25` (㎍/㎥) — **위험 판단 사용** |
| `winsp`, `windir`, `temp`, `humi` | `wind_speed`(m/s), `wind_dir`, `temp`, `humidity` — 참고용 |
| `o3, no2, so2, co, voc, h2s, nh3, hcho` (ppm), `co2` (**%** 부피비 — 0.04% = 400ppm), `ou`, `batt` | 같은 이름(`ou`→`odor`, `batt`→`battery`)으로 저장만 |
| `logDateTime` | `observations.observed_at` = **원천 측정 시각** (수위계와 다름) |
| `uvIndex`, `dateTime` | 가상 관측소 `external_id='uv_latest'`, `kind='uv'` (좌표는 구룡포행정복지센터) · metric `uv_index` |

**수집기 (A2)** — `tools/pohang_dt_air.py`
- `normalize_devices()`(하루 1회) · `normalize_realtime()` · `normalize_uv()`(10분마다) → SQL 은 `pohang_dt_water.py` 의 `UPSERT_STATION_SQL`, `INSERT_OBSERVATION_SQL` 재사용
- 같은 값을 다시 받아도 PK `(station_id, metric, observed_at)` 로 중복 저장 안 됨
- `logDateTime` 이 비었거나 값이 전부 0인 행은 `skipped` (확인 당시 7번)
- **갱신이 멈춘 장비가 섞여 옴** (확인 당시 5번 6월, 6번 8월, 10·15·18번 반나절~하루 전) → 저장은 하되 **위험 판단은 60분 이내 값만** (`FRESH_LATEST_SQL`). 실제 판단 사용 장비는 17대
- 앱 표기: 수위계와 달리 **"20:54 측정"**

**판단 기준 (`risk_rules`)** — 기존 id 유지, 새 기준은 끝에 추가

| id | 재난 | 단계 | 기준 | 출처 |
|---|---|---|---|---|
| 29 | 미세먼지 | watch (나쁨) | PM10 81~150 (순간값) | 에어코리아 예보등급 |
| 12 / 13 | 미세먼지 | 주의보 / 경보 | PM10 시간평균 150 / 300 이상 2시간 지속 | 대기환경보전법 시행규칙 |
| 30 | 초미세먼지 | watch (나쁨) | PM2.5 36~75 (순간값) | 에어코리아 예보등급 |
| 14 / 15 | 초미세먼지 | 주의보 / 경보 | PM2.5 시간평균 75 / 150 이상 2시간 지속 | 대기환경보전법 시행규칙 |
| 16~20 | 자외선 | 낮음~위험 | 0–2 / 3–5 / 6–7 / 8–10 / 11+ | 기상청 자외선지수 |

- 미세먼지: 측정기 반경 **300m** 영향 범위, `condition.max_age_min = 60`
- "2시간 지속"은 `DUST_SUSTAINED_SQL` 로 근사 (최근 2시간을 1시간 구간 2개로 나눠 두 구간 평균이 모두 기준 이상)
- 자외선: 좌표 없는 전역 값 → 버퍼 대신 **구룡포읍 전체**에 적용 (`condition.area = "guryongpo"`), 90분 이내 값만
- 강풍: DT 측정기 `winsp` 는 지상 저고도 센서라 **판단에서 제외**, 기상청 관측만 사용 (3·4번)
- 오존·NO₂ 등 가스는 저장만 (hazard 종류에 없음 — 필요 시 추가 논의)

## 5-3. 기상청 동네예보 연동 (API허브)

**API** — `https://apihub.kma.go.kr/api/typ02/openApi/VilageFcstInfoService_2.0/<오퍼레이션>` · `authKey`(=`KMA_KEY`) · `dataType=JSON`

| 오퍼레이션 | 발표 · 조회 가능 | 저장 | 원문 |
|---|---|---|---|
| `getUltraSrtNcst` 초단기실황 | 매시 정각 · +40분 | `observations` (격자 가상 관측소) | `mock/external/kma_ncst_*.json` |
| `getUltraSrtFcst` 초단기예보 (6시간) | 매시 30분 · +45분 | `forecasts` kind `ultra_short` | `kma_fcst_*.json` |
| `getVilageFcst` 단기예보 (약 4일) | 02·05·08·11·14·17·20·23시 · +10분 | `forecasts` kind `short` | `kma_vil_*.json` |

- `base_date`/`base_time` 은 `fetch_dt.py` 의 `kma_times()` 가 호출 시각 기준 최신 발표분으로 자동 계산
- 단기예보는 1회 약 1,016건 → `numOfRows=1500` (1000 이면 잘림)
- 정상 판정: `response.header.resultCode == "00"`

**구룡포 격자** (위경도 → 기상청 5km 격자 변환, 포항시청 (102,94) 로 검증)

| 격자 (nx, ny) | 포함 지역 | 수집 |
|---|---|---|
| **105, 94** | 구룡포읍 중심 · 병포리 · 행정복지센터 | ✅ |
| **106, 94** | 구룡포항 · 방파제 | ✅ |
| 105, 93 / 106, 95 | 구평리 / 다무포 | 필요 시 추가 |

**매핑**
- 초단기실황 → `stations`(`source_code='kma'`, `kind='weather'`, `external_id='grid_105_94'`) + `observations`
  `T1H→temp`, `RN1→rain_1h`, `REH→humidity`, `WSD→wind_speed`, `VEC→wind_dir`, `PTY→precip_type` (UUU·VVV 저장 안 함), `observed_at = base_date+base_time`
- 예보 → `forecasts` 에 category 원문 그대로 (`value` 원문, `value_num` 숫자). 강수 범주 문자열은 하한값으로 변환: `강수없음`=0, `1mm 미만`=0.5, `30.0~50.0mm`=30, `50.0mm 이상`=50
- 같은 예보 시각은 여러 번 발표되므로 조회는 `v_latest_forecasts`(가장 최근 발표값) 사용
- 대시보드 `forecast` 위젯 `slots[{t, pop, pty, pcp_mm, tmp, wsd}]` ← `POP, PTY, PCP(value_num), TMP(초단기는 T1H), WSD`

**판단 기준과의 관계**
- 초단기실황 `rain_1h` 가 정시마다 들어오므로 `RAIN_SUM_SQL` 로 3·12시간 누적 → 호우특보 기준(1·2번) 판단 가능
- 초단기실황에는 **순간풍속이 없음** → 강풍 기준 중 순간풍속 조건(`wind_gust`)은 AWS 지상관측 연동 후 사용, 그 전에는 평균풍속(`wind_speed`) 조건만
- 단기예보 `WAV`(파고)는 풍랑 기준(5·6번 `wave_height`) 의 **예보값**으로 참고 가능 (관측값은 별도)
- 확인 당시 값: 기온 18.8°C, 습도 94%, 풍속 1.4m/s, 강수 없음, 파고 0.5m

## 5-4. 기상청 기상특보 · 중기예보 · AWS 연동 (API허브)

**기상특보 현황** — `typ01/url/wrn_now_data.php?fe=f&tm=&disp=1&authKey=` (10분마다)
- 응답: JSON 배열, 발효 중 특보 없으면 `[]`. `tm=YYYYMMDDHHMM` 로 과거 시점 재현 가능 → 힌남노(2022-09-05 18시) 원문 `mock/external/kma_wrn_hinnamno.json` (276건, 시연 시나리오용)
- 필드: `REG_ID, REG_KO, TM_FC(발표), TM_EF(발효), WRN(종류), LVL(예비/주의/경보), CMD(발표/변경), ED_TM(해제 예고 문구)` — 값 끝 공백 strip
- 구룡포 관련 구역 (`wrn_reg.php` 로 확인): **`L1072400` 포항시** · **`S1131200` 경북남부앞바다** · `S1132210` 동해남부북쪽안쪽먼바다(먼바다 조업)

| 원문 | → `weather_warnings` |
|---|---|
| `WRN` 호우/강풍/태풍/풍랑/폭풍해일 | `hazard` heavy_rain/strong_wind/typhoon/high_seas/flood (그 외 종류는 저장 안 함) |
| `LVL` 예비/주의/경보 | `level` **watch**(예비특보 — 스키마 CHECK 에 추가)/advisory/warning |
| `TM_FC`, `TM_EF` | `issued_at`, `effective_at` |
| `TM_EF`+`WRN`+`LVL` | `external_id` (단계가 바뀌면 새 행) |
| (목록에서 사라짐) | `released_at` = 수집 시각 (`RELEASE_MISSING_SQL`) |
| `ED_TM` | `headline` 에 "해제 예고" 로 표시, 원문은 `raw` |

**중기예보** — `typ02/openApi/MidFcstInfoService/…` · 06·18시 발표 · `tmFc` 자동 계산
| 오퍼레이션 | regId | 내용 | → `forecasts` (kind `mid`, `region_code`=regId) |
|---|---|---|---|
| `getMidLandFcst` | **11H10000** 대구·경북 | 5~10일 `wf`(날씨), `rnSt`(강수확률) 오전/오후 | category `wf5Am`… / `rnSt5Am`…, `fcst_time` = 해당 일 09시(Am)·15시(Pm)·12시(8일 이후) |
| `getMidTa` | **11H10201** 포항 | 5~10일 `taMin`/`taMax` (+Low/High 범위) | category `taMin5`…, `fcst_time` = 해당 일 06시(min)·15시(max) |
- 위험 판단에는 사용하지 않음 (여행 계획 · "다음 주 날씨" 질문용). 3~4일은 단기예보로 커버

**AWS 매분 자료 (구룡포 지상관측)** — `typ01/cgi-bin/url/nph-aws2_min?tm1=&tm2=<KST>&stn=816&disp=1` (10분마다)
- **구룡포 AWS = 지점번호 `816`** (35.9831, 129.5475 · 해발 42.4m · 구룡포읍 중심에서 0.3km) — 방재기상관측 지점 일람표(`AwsYearlyInfoService/getAwsStnLstTbl`)로 확인. 보조: `808` 호미곶(10km), `138` 포항 ASOS
- `stn=0`(전 지점)은 빈 응답 → 반드시 지점 지정. 결측은 -50 이하

| 원문 | metric | 쓰임 |
|---|---|---|
| `WS10` / `WD10` | `wind_speed` / `wind_dir` | 강풍 기준(3·4번) 평균풍속 |
| **`WSS`** 최대 순간 풍속 | **`wind_gust`** | 강풍 기준 순간풍속 |
| `RN-60m` | `rain_1h` | `RAIN_SUM_SQL` 로 3시간 누적 → 호우 기준(1·2번) |
| **`RN-12H`** | **`rain_12h`** | 호우 기준 12시간 누적 **직접 사용** |
| `RN-15m`, `RN-DAY`, `TA`, `HM`, `PS` | `rain_15m`, `rain_day`, `temp`, `humidity`, `pressure_sea` | 대시보드·Agent |

- 확인 당시(2026-09-26 22:38): 풍속 1.6m/s, 순간 2.3m/s, 기온 18.8°C, 습도 94%, 일강수 1.5mm
- 우선순위: 강풍·호우 판단은 **AWS 816 실측 > 초단기실황(격자)**. AWS 결측 시 초단기실황으로 대체
- AWS 시간통계 바람(`awsh.php`)은 전 지점만 조회돼 느림 → 보조용, 기본 수집에서 제외

## 5-5. 기상청 태풍정보 연동 (API허브)

| API | 경로 | 용도 |
|---|---|---|
| 태풍 목록 | `typ01/url/typ_lst.php?YY=<올해>&disp=1` | 번호·이름·진행여부(`NOW` 1진행/2종료)·한반도영향(`EFF` 1상륙~4없음) |
| 위치+예측 | `typ01/url/typ_now.php?tm=<UTC>&mode=1&disp=1` | 활동 중 태풍 전체의 분석 이력 + 최신 예측(6~120h) — 번호 몰라도 한 번에 |

- **시각은 모두 UTC** (요청 `tm` 포함) → 저장 시 KST 변환. `fetch_dt.py` 는 `NOW_TM_UTC` 사용
- 필드: `FT`(0분석/1예측), `TYP_TM`(분석), `FT_TM`(예측), `LAT, LON, DIR, SP, PS, WS, RAD15(강풍반경), RAD25(폭풍반경), RAD(70% 확률반경), LOC(위치 문구)` · 결측 `-999`
- `typhoon_tracks` 에 `issued_at, direction, speed_kmh, prob_radius_km, location_text` 컬럼 추가. `typhoon_code` = 연도 2자리+번호 (힌남노 `2211`)
- 수집: 태풍 진행 중(`NOW=1`)일 때만 3시간마다 (분석 발표 주기)

**영향권 판단** (`kma_typhoon.impact()` → `risk_rules` 7·8번)
- 현재 위치와 구룡포 거리 ≤ `radius_15ms_km` → 태풍 영향권(advisory), ≤ `radius_25ms_km` → warning
- 최신 예측 경로에서 반경 진입 예정(`will_enter_*`)·최근접 시각/거리 → 선제 경고 문구 ("09시경 약 50km 까지 접근")

**시연 데이터 — 힌남노**
- `kma_typ_hinnamno.txt`: 2022-09-06 03시 KST 분석 (통영 남남서 80km, 950hPa, 43m/s, 강풍반경 400km) → 구룡포 243km, **이미 강풍반경 안**, 예측상 09시 KST 약 51km 최근접·폭풍반경 진입
- 같은 시점 특보 `kma_wrn_hinnamno_0603.json` (tm=202209060300 KST, 272건): **포항시 태풍경보**(00시 발효), **경북남부앞바다 태풍경보**, 동해남부북쪽안쪽먼바다 태풍경보 — 태풍 mock 과 시각 일치
- 현재(2026-09-26): 제26호 수리개 진행 중, 구룡포 최근접 약 880km (영향 없음)

## 5-6. 산사태 취약지역 (공공데이터포털 파일데이터)

| 파일 (폴더에 CSV 그대로, CP949) | 행 | 쓰임 |
|---|---|---|
| 경상북도_산사태취약지역지정현황 ([15126579](https://data.go.kr/data/15126579/fileData.do)) | 8,187 (포항 488) | **좌표**(위경도 도·분·초), 유형, 지정면적 |
| 경상북도 포항시_산사태 취약지역 현황 ([15123337](https://data.go.kr/data/15123337/fileData.do)) | 394 | **지정사유**, 관리주체, 소유별, 대피소와의 거리 — 좌표 없음 |

- 두 파일을 (읍면동, 리, 지번, 유형)으로 결합 → 포항 488곳, 설명 매칭 392/394. **구룡포읍 19곳** (토석류 15 · 산사태 4)
- 원천이 **점 + 면적**이라 폴리곤이 없음 → 중심점에서 반경 `max(√(면적/π), 50m)` 원을 `hazard_zones.geom` 으로 저장 (토석류는 계곡형이라 근사). 판단 규칙 10번(산사태 주의)은 여기에 **100m 버퍼**, 11번(경고)은 영역 내부
- `hazard_zones`: `hazard='landslide'`, `grade`=취약지역유형(산사태/토석류), `meta`={lat, lng, area_m2, radius_m, emd, reason, manager, ownership, shelter_distance_m, designated_date}
- 생성: `python3 tools/landslide_zones.py` → `db/seed_landslide.sql`, `mock/external/landslide_guryongpo.geojson`(구룡포 19곳, C 지도 확인용)
- CSV 가 갱신되면 새 파일을 폴더에 넣고 다시 실행 (파일명 앞부분으로 찾음)

## 5-7. 행동요령 · 지원제도 · 긴급전화 (포항시 재난안전 홈페이지)

원문 `https://www.pohang.go.kr/safe/contents.do?mid=…` (2026-09-26 확인) → `tools/seed_knowledge.py` → `db/seed_knowledge.sql`. 원문 문장을 요약·정리 (의미 변경 없음), 모든 행에 `source_url`.

| 테이블 | 내용 | 원문 mid |
|---|---|---|
| `action_guides` 51행 (30항목 × 재난) | 호우·태풍 주의보/경보, 강풍·풍랑경보 (도시·농촌·해안 구분), 호우·태풍 올 때(가정·보행자·차량·상습침수·산간·어촌·야영장), 호우·태풍 후 | 0301010000·0200·0300, 0301030000·0200 |
| `support_programs` 9 | 풍수해·지진재해보험, 양식수산물·농작물·가축 재해보험, 포항시민안전보험(자동가입), 사망·실종·부상 구호금, 이재민 응급·장기구호, 세입자 보조, 농·어업인 생계지원 | 0400000000, 0405000000, 0403000000, 0500000000 |
| `public_hotlines` 20 (+ seed.sql 전국 4) | **구룡포읍 행정복지센터 대표 054-270-6563 · 건설팀(재난·하천) · 해양수산팀 · 주민복지팀(이재민 구호) · 산업팀(농업재해)**, 포항시청 민원콜(24h), 남부소방서·남부경찰서(구룡포 관할), 해양경찰서, 해양수산청, 한전, 가스안전공사, 종합병원 5곳, 110, 중앙재난안전상황실 | 0301050300 (비상시 주요기관 연락처) |

- 원문 구분 → 우리 규약: 특보 발령 시 = `phase='during'` + `min_level` advisory/warning, "올 때" = during·watch, "후" = after. 도시지역 = `{all}`, 농촌 = `{farmer}`, 해안 = `{fisher,vessel_owner,coastal}` (target 태그에 `coastal`, `farmer` 추가)
- `voice_text`: 위급도가 높은 항목에만 음성 안내용 한 문장
- **제외**: 지진해일(0301060000)·응급처치(0301050200) — 지진해일은 재난 종류에 넣지 않기로 결정
- 모든 seed 는 PostgreSQL 16 에서 실제 적재 확인 (PostGIS 함수만 대체 스텁) — 테이블 30 · 뷰 2 · 규칙 30 · 산사태 488 · 행동요령 51 · 지원제도 9 · 긴급전화 19

## 5-8. 재난문자 · 대피소 · 응급의료 (진행 중)

- **재난문자**: 공공데이터포털 [행정안전부_긴급재난문자](https://www.data.go.kr/data/15134001/openapi.do) (재난안전데이터공유플랫폼 제공). 국민안전24 화면도 같은 데이터를 보여 주므로 스크래핑 불필요. 지연 시간은 키 발급 후 최신 문자의 발송시각과 수집시각을 비교해 확인 예정
  - 설계 원칙: 재난문자는 휴대폰 셀방송(CBS)으로 **이미 즉시** 수신됨 → 앱의 1차 경보는 DT 센서·AWS·특보 기반 자체 판단(10분 주기)이고, 재난문자는 대시보드 이력·Agent 설명용 (수 분 지연 허용)
- **대피소 (완료)** → `db/seed_shelters.sql`, `mock/external/shelters_guryongpo.geojson` — **구룡포 19곳**
  - 원천: 생활안전지도 오픈API (`SAFEMAP_KEY`) `IF_0126` 지진해일 긴급대피장소 (전국 830 → 구룡포 17, 실외 고지대) · `IF_0122` 민방위대피시설 (전국 17,231, 1000건씩 18쪽 → 구룡포 2: 해뜨는마을·여의주타워 지하주차장)
  - 원천에 **좌표가 없음(주소만)** → 위도·경도 변환 필요. OpenStreetMap(Nominatim)은 19곳 중 2곳만 번지까지 찾음(나머지는 도로 대표점) → 부적합
  - 변환: `tools/geocode_shelters.py` (카카오 로컬 REST API, `KAKAO_REST_KEY`). 지진해일 대피장소 13곳은 **카카오맵 등록 장소 '지진해일대피장소 ○○' 좌표**로 보정 (`KAKAO_PLACES`), 나머지 6곳은 도로명 주소 검색
  - 보정 이유: 생활안전지도 주소가 틀리거나 검색 안 되는 곳 있음 — 예) 대성수산 입구 앞: 이름 검색은 내륙 3km 다른 가게를 잡음, 실제 석병리 20-1(해안) / 해은사 앞: 원천 '호미로 417' 검색 불가, 실제 구룡포리 94-14
  - 좌표는 WGS84 → OpenStreetMap 지도·GraphHopper 에 그대로 사용. `shelter_types` = `{tsunami}`(실외) / `{civil_defense}`(지하·실내)
  - 참고: 카카오맵에는 원천 목록에 없는 구룡포 지진해일대피장소 2곳(한빛수산 입구 도로, 브리즈나인 커피숍 앞 주차장)이 더 있음 — 필요 시 추가
- **응급의료 (완료)** → `db/seed_medical.sql`, `mock/external/medical_pohang.geojson` — 국립중앙의료원 전국 응급의료기관 정보 조회 서비스 (`DATA_GO_KR_KEY`, 생활안전지도 `IF_0047` 은 폐기됨)
  - `https://apis.data.go.kr/B552657/ErmctInfoInqireService/` · XML
  - `getEgytListInfoInqire?Q0=경상북도&Q1=포항시` → 포항 응급의료기관 **5곳**: 포항성모병원(권역응급의료센터), 포항세명기독병원(지역응급의료센터), 에스포항병원·좋은선린병원·포항의료원(지역응급의료기관). `medical_facilities` kind=`emergency_room`, `meta`={er_phone(응급실 직통), emergency_class}
  - **구룡포 안에는 응급의료기관 없음** — `getEgytLcinfoInqire`(구룡포읍 기준): 세명기독 17.2km · 선린 17.7km · 포항의료원 18.2km → Agent 는 "응급실이 멀다 → 119 먼저" 안내
  - `getEmrrmRltmUsefulSckbdInfoInqire?STAGE1=경상북도&STAGE2=포항시` (철자 `Rltm` 주의) → 새 테이블 **`er_availability`** (응급실 hvec, 수술실 hvoc, 입원실 hvgc, 구급차 hvamyn, 입력시각 hvidate) · 10분 주기 · `nmc_medical.UPSERT_AVAILABILITY_SQL`. 응급실 병상 음수 = 과밀
  - `Q1` 은 '포항시'(전체 5곳) 또는 '포항시남구'(3곳, 띄어쓰기 없이). '포항시 남구'는 0건

## 6. 공통 규칙

- 시각: ISO 8601 KST (`+09:00`)
- 에러: `{ "code": "...", "message": "사용자에게 보여줘도 되는 한국어", "detail": ... }`
  코드: `UNAUTHORIZED, NOT_FOUND, VALIDATION_ERROR, STT_FAILED, AGENT_TIMEOUT, UPSTREAM_UNAVAILABLE, INTERNAL`
- `/chat` 타임아웃 30초 → 504 `AGENT_TIMEOUT` (detail 에 기본 안전 안내)
- `/route` 가 503이면 앱은 `nearest_shelters` + 직선 방향으로 폴백

## 7. B·C 검토 체크리스트

**B (GraphHopper·Agent 쪽)**
- [ ] `POST /route` 요청의 `profile`(fastest/safe/elderly/wheelchair/car)·`avoid` 항목을 GraphHopper custom model 로 구현 가능한가
- [ ] `Route.instructions[].interval`, `avoided`, `remaining_risks` 를 GraphHopper 응답에서 채울 수 있는가
- [ ] `/route/check` 30초 주기가 서버 부하상 괜찮은가
- [ ] `risk_assessments.area`(폴리곤)를 GraphHopper 회피 영역으로 넘기는 방식 합의
- [ ] Agent 가 쓰는 테이블이 충분한가 (특히 `action_guides.targets` 태그 목록)
- [ ] `ChatMessage.blocks` 종류 (table, action_steps, checklist, risk_card, shelter_card, route_card, call_button) 로 충분한가

**C (Flutter 쪽)**
- [ ] 목업 JSON 만으로 대시보드(평상시/재난)·지도·알림·채팅·경로 화면을 그릴 수 있는가
- [ ] 위험 단계 색상 5개 확정
- [ ] `Widget.type` 10종 중 1차 구현 범위 결정
- [ ] 지도 SDK 에서 GeoJSON `[lng, lat]` 순서 처리 확인
- [ ] Firebase 익명 로그인·FCM 설정 (iOS APNs 키 포함) 가능 여부
- [ ] 녹음 포맷 (iOS m4a / Android m4a·webm / 웹 webm) 확인

## 8. 남은 확인 사항 (A)

1. 포항 디지털 트윈 — 수위계·대기환경·자외선 반영 완료, API 4개 모두 `fetch_dt.py` 에 등록. 남은 확인 없음
2. ~~구룡포 단기예보 격자 (nx, ny)~~ → (105,94)·(106,94) 확정. 기상특보·중기예보 완료 (5-4). 구룡포 AWS `816`, 태풍정보 완료 (5-4·5-5). **기상청 연동 완료**
3. ~~산사태 위험지역 데이터 형식~~ → 취약지역 점+면적 → 원형 근사 (5-6). 필요 시 산림청 산사태위험지도(등급 폴리곤)로 정밀화
4. 건강정보(`medical_note`, `blood_type`) 수집 동의 화면 문구
5. PostGIS 환경에서 `schema.sql` 재실행 확인 (검증은 PostGIS 없이 geometry 를 대체 타입으로 바꿔 수행) — 서버(PostgreSQL 17.6 + PostGIS 3.5.3)에서 최종 확인
6. ~~지진해일 hazard~~ → 추가하지 않기로 결정 (지진해일 대피소는 해안 고지대 대피장소로 `shelters.shelter_types` 에만 사용). 응급처치 안내는 재난 공통 항목이라 이번 범위 제외
7. ~~구룡포읍 행정복지센터 전화번호~~ → 직원안내 페이지에서 확인, `public_hotlines` 5건 추가
