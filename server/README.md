# 구룡가디언 서버 (A — API · 데이터 수집 · 위험 판정)

포항 디지털 트윈·기상청 데이터를 주기적으로 모아 PostgreSQL 에 쌓고(`collector`), 위험을 판정하고(`risk`),
앱·Agent 가 부르는 REST API(`app`)를 제공한다.

```
server/
  app/                 FastAPI (api 서비스)
    main.py            앱 생성, /api/v1 라우터, /api/health
    config.py          설정 (환경 변수 = 루트 .env, 로컬 스크립트용 server/dt_config.txt)
    auth.py            Firebase ID 토큰 검증 (current_user / optional_user / require_internal)
    errors.py          공통 에러 { code, message, detail }
    db.py              psycopg 3 풀 + fetch_all / fetch_one / execute / execute_many
    health.py          /api/health 계산 (DB + 수집 작업 신선도 + route·ai)
    layers.py          지도 레이어 (stations·landslide_zones 실데이터)
    mocks.py           목업 응답 (X-Mock: true)
    schemas.py         요청 본문 모델 (spec/openapi.yaml 과 같은 제약)
    routers/           system · user · dashboard · risk · alerts · chat · route · internal
  collector/           수집기 (collector 서비스 — 같은 이미지, `python -m collector`)
    jobs.py            작업 12개 정의 (호출 → 변환 → 적재 → ingest_runs)
    fetch.py           live 호출 / replay(저장 원문) · 기상청 발표시각 계산
    store.py           DB upsert
    scheduler.py       APScheduler (Asia/Seoul)
    converters/        tools/ 변환기 사본 (이후 수정은 여기서)
  loader/              정적 데이터 적재 (A7) — db/init 스키마·시드 적용, 재실행 안전 (docker compose run --rm loader)
  risk/                판정 엔진 (A3)
    engine.py          최신 관측값 + risk_rules → risk_assessments 동기화
    queries.py         /risk (좌표), /risk/areas (영역 GeoJSON)
    simulate.py        시연 시나리오 (모의 관측값 주입)
  spec/openapi.yaml    API 명세 (https://editor.swagger.io 에 붙여넣으면 문서)
  mock/                목업 응답 JSON · mock/external = 원천 API 저장 원문 (replay·테스트용)
  docs/spec.md         1주차 DB 스키마·API 명세·데이터 연동 상세 (ERD: ../db/erd.png)
  tools/               개발 스크립트 (API 일괄 호출, 시드 SQL 생성, 목업 검증) — tools/README.md
  data/                산사태 취약지역 CSV 원본 (공공데이터포털)
  tests/               pytest (DB 없이 동작, DB 통합은 TEST_DATABASE_URL 있을 때)
../db/init/            00 PostGIS · 01 스키마 · 02 판단 기준·관측소 · 03 산사태 · 04 행동요령 · 05 대피소 · 06 응급의료
```

## 1. 실행 (저장소 루트에서)

```bash
cp .env.example .env                      # 키는 팀 비공개 채널에서: KMA_API_KEY, POHANG_TWIN_API_KEY
docker compose up -d --build              # db · api · collector (+ ai · graphhopper · route)
curl localhost:8000/api/health            # status, db, components(ingest.pohang_dt · ingest.kma · ingest.risk · route · ai)
docker compose logs -f collector          # 수집·판정 로그
docker compose exec api python -m collector --once              # 전체 1회 실행 → 결과 표
docker compose exec api python -m collector --once kma.aws      # 작업 하나만
```

- DB 는 볼륨이 비어 있을 때만 `db/init/*.sql` 을 이름 순서대로 실행한다.
- **시드(02~)가 바뀌면** `docker compose run --rm loader` — 수집한 관측값·사용자 데이터는 두고 정적 데이터만 다시 적재 (여러 번 실행해도 결과 같음)
- **스키마(01)가 바뀌면** loader 가 없는 테이블을 알려 주고 멈춘다 → 로컬은 `docker compose down -v` 후 다시 up, 배포 DB 는 해당 CREATE 문 직접 적용

### 정적 데이터 적재 — loader (A7)

```bash
docker compose run --rm loader              # 02 판단 기준·관측소·맨홀 · 03 산사태 · 04 행동요령 · 05 대피소 · 06 응급의료
docker compose run --rm loader --dry-run    # 적용해 보고 되돌림 (행 수만 확인)
docker compose run --rm loader --check      # 적용 없이 행 수 확인 — 최소 행 수 미달이면 종료 코드 1
```

- 전 파일을 한 트랜잭션으로 적용 → 중간에 SQL 오류가 나면 전부 되돌리고 DB 는 그대로 (종료 코드 2)
- 빈 DB(initdb 를 거치지 않은 DB)면 00·01 스키마부터 만든다 → `createdb` 만 한 테스트 DB 도 loader 한 번으로 준비
- 적재 기록: `ingest_runs` (source_code=`loader`, job=`static_seed`, row_count = 정적 테이블 행 합계)
- 시드 규칙: 여러 번 적용해도 같은 결과여야 함 — upsert(`ON CONFLICT`) 또는 참조 없는 테이블은 `TRUNCATE ... RESTART IDENTITY` 후 삽입.
  `risk_rules` 는 id 를 고정(1~30)해서 upsert (판정 결과·문서가 번호로 참조). 검사: `tests/test_loader.py::test_seeds_are_rerunnable`
- 테이블별 최소 행 수는 `loader/core.py` 의 `REQUIRED` (원천이 줄었거나 생성 스크립트가 잘못됐을 때 경고)
- 서버 모드(배포): `docker compose -f docker-compose.yml up -d --build` — override(코드 마운트·DB 포트)가 빠진다
- 네트워크·키 없이: `.env` 에 `COLLECTOR_FETCH_MODE=replay` → `server/mock/external` 저장 원문(2026-09-26 실측)으로 적재

### 로컬 파이썬 (테스트·디버깅)

```bash
cd server
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/python -m pytest -q                                   # DB·네트워크 없이 (API 골격 + 수집 replay + 판정 규칙)
DATABASE_URL=postgresql://guardian:guardian-local-only@localhost:5433/guardian .venv/bin/python -m collector --once
```

### 환경 변수 (루트 `.env`)

| 키 | 기본 | 설명 |
|---|---|---|
| `API_AUTH_MODE` | `firebase` (.env.example 은 `dev`) | `dev` 면 `Authorization: Bearer dev:<uid>` 허용. 배포는 firebase |
| `API_INTERNAL_TOKEN` | 없음 | `/api/v1/internal/*` 헤더 `X-Internal-Token`. 없으면 dev 모드에서만 허용 |
| `FIREBASE_CREDENTIALS` · `GCP_PROJECT_ID` | `secrets/firebase-admin.json` | ID 토큰 검증 (api 컨테이너에 `secrets/` 읽기 전용 마운트) |
| `KMA_API_KEY` | – | 기상청 API허브 authKey |
| `POHANG_TWIN_API_KEY` · `POHANG_TWIN_BASE_URL` | – · `https://genix.pohang-eum.kr/dpg` | 포항 디지털 트윈 serviceKey |
| `COLLECTOR_FETCH_MODE` | `live` | `replay` = 저장 원문으로 적재 |
| `COLLECTOR_IN_API` | `false` | api 컨테이너 안에서도 스케줄러 (collector 없이 쓸 때만) |

`server/tools/` 스크립트는 `server/dt_config.txt`(gitignore)의 `DT_KEY`·`KMA_KEY`·`SAFETYDATA_KEY`·`KAKAO_REST_KEY` 등을 읽는다. 서버도 이 파일이 있으면 읽는다(환경 변수가 우선).

## 2. 수집 작업 (`python -m collector --list`)

| 작업 | 주기 (KST) | 적재 | stale 기준 |
|---|---|---|---|
| `pohang_dt.water_level` 수위계 10개 | 10분 | stations · observations (observed_at = 수집 시각) | 30분 |
| `pohang_dt.air_realtime` 대기환경 23대 | 10분 | observations (observed_at = logDateTime) | 30분 |
| `pohang_dt.uv` 자외선 | 10분 | observations (가상 관측소 `uv_latest`) | 90분 |
| `pohang_dt.air_devices` 대기 장비 목록 | 매일 04:05 | stations | 26시간 |
| `kma.warnings` 기상특보 | 10분 | weather_warnings (+ 사라진 특보 released_at) | 30분 |
| `kma.aws` 구룡포 AWS 816 | 10분 | observations (풍속·순간풍속·강수·기온…) | 30분 |
| `kma.ncst` 초단기실황 (105,94)(106,94) | 매시 45분 | observations | 130분 |
| `kma.ultra_fcst` 초단기예보 | 매시 20분 | forecasts `ultra_short` | 130분 |
| `kma.vilage_fcst` 단기예보 | 02·05·…·23시 20분 | forecasts `short` (격자당 약 1,016건) | 7시간 |
| `kma.mid_fcst` 중기예보 | 06:30 · 18:30 | forecasts `mid` | 26시간 |
| `kma.typhoon` 태풍 | 3시간마다 10분 | typhoon_tracks (진행 중 태풍 없으면 건너뜀) | 7시간 |
| `risk.flood` 침수·강우 판정 | 10분 (1·11·21…분, 수위 수집 1분 뒤) | risk_assessments | 30분 |

- 스케줄러를 켜면 모든 작업을 **시작 직후 1회** 실행한다 (몇 초 간격으로 분산)
- 실패해도 스케줄러는 멈추지 않고 `ingest_runs.status='failed'`, `error` 에 원인 (키는 `***` 로 가림)
- 기상청 호출량: 하루 약 420회
- 수동 실행: `POST /api/v1/internal/ingest/{source}/{job}` (헤더 `X-Internal-Token`), 최근 실행: `GET /api/v1/internal/ingest`

## 3. API 상태

| 엔드포인트 | 상태 |
|---|---|
| `GET /health` (`/api/health` 도 같음) | **실데이터** — DB + 수집 작업 신선도. DB 가 죽으면 503 |
| `GET /risk?lat=&lng=[&radius_m=]` | **실데이터** — 좌표가 들어간 위험 영역을 재난별 최고 단계로 (A3: 침수·포항 DT 강우) |
| `GET /risk/areas`, `/dashboard/layers/risk_areas` | **실데이터** — 현재 위험 영역 GeoJSON (MultiPolygon) |
| `POST /api/v1/internal/simulate` | **실데이터** — 시연 시나리오 `heavy_rain_flood`, `clear` |
| `GET /risk/rules` | **실데이터** — risk_rules 30개 |
| `GET /dashboard/layers/stations` | **실데이터** — 관측소 + 최신값 (`level` 은 포항 DT 등급, 대기 60분·자외선 90분 넘으면 `stale: true`) |
| `GET /dashboard/layers/landslide_zones` | **실데이터** — 산사태 취약지역 |
| 그 외 (`/user`, `/dashboard`, `/risk`, `/alerts`, `/chat`, `/voice`, `/route` …) | 목업 (`X-Mock: true`) — 요청 검증·인증은 실제와 동일 |

### 침수 판정 (A3)

- 입력: 포항 DT 수위계(맨홀 3·지표면 5·하천 1)·강우량계 1의 최신값 (수집 40분 이내)
- 기준: DB `risk_rules` 를 읽어 적용 — 9번(지표면 침수심 ≥ 150mm, 반경 150m), 21~24번(수위계 DT 등급 2~5, 반경 100/150/300/500m), 25~28번(강우량계 DT 등급 2~5 → 구룡포읍 반경 4km)
- 관측소마다 가장 높은 단계 1개. 같은 단계면 15cm 침수심 기준을 우선 (근거 문장이 구체적)
- `risk_assessments`: 같은 판정이 이어지면 **같은 행(area_id) 유지**, 단계가 바뀌면 이전 행을 닫고 새 행, 정상이면 닫음.
  수집이 끊긴 관측소의 영역은 3시간 유지 (끊겼다고 '안전'으로 보이지 않게). `/risk` 의 `data_stale` 로 지연 표시
- `/risk` 의 `items[].location` 은 위험의 **원인 관측소** 위치 (조회 좌표 아님)

### 시연 시나리오

```bash
T=$(grep '^API_INTERNAL_TOKEN=' .env | cut -d= -f2)      # dev 모드에서 비워 두면 헤더 없이도 됨
curl -X POST localhost:8000/api/v1/internal/simulate -H "X-Internal-Token: $T" -H 'Content-Type: application/json' -d '{"scenario":"heavy_rain_flood"}'
curl "localhost:8000/api/v1/risk?lat=35.99069&lng=129.556057"      # 구룡포환승센터 → 침수 경보 230mm
curl -X POST localhost:8000/api/v1/internal/simulate -H "X-Internal-Token: $T" -H 'Content-Type: application/json' -d '{"scenario":"clear"}'
```
모의값은 `observations.quality='simulated'` 로 저장되고 6시간 동안 실측보다 우선 (판정·지도 모두). `clear` 로 삭제.
배포 서버에서는 `X-Internal-Token` 헤더 필요.

목업 편의 기능: `GET /dashboard?...&scenario=emergency` 로 재난 모드 화면, `/alerts` 에 `since` 를 주면 빈 목록(중복 제거 확인용), `/user` 는 호출한 uid 로 채워서 반환.

## 4. 인증

- 기본 `API_AUTH_MODE=firebase`: `Authorization: Bearer <Firebase ID 토큰>` 을 `firebase_admin.auth.verify_id_token` 으로 검증
  - 서비스 계정 키: Firebase 콘솔 → 프로젝트 설정 → 서비스 계정 → 새 비공개 키 → 경로를 `FIREBASE_CREDENTIALS` 에 (커밋 금지)
  - 만료 → 401 `token_expired` (앱은 `getIdToken(true)` 로 갱신 후 재시도)
- `API_AUTH_MODE=dev`: `Authorization: Bearer dev:아무거나` 도 통과 → C·B 가 Firebase 설정 전에 목업 API 호출 가능. **배포 서버에서는 사용 금지**
- 토큰 없이 되는 것: `/health`, `/risk*`, `/dashboard/layers/*`, `/voice/audio/*` (명세 5장)

```bash
curl -H "Authorization: Bearer dev:harin" "localhost:8000/api/v1/dashboard?lat=35.9858&lng=129.5481"
```

## 5. 테스트

```bash
cd server && .venv/bin/python -m pytest -q        # DB·네트워크 없이
# 실제 PostGIS 통합 테스트 — 운영 DB 와 분리된 guardian_test DB 를 만들어서 (저장소 루트에서)
docker compose exec db sh -c 'createdb -U "$POSTGRES_USER" guardian_test'
docker compose run --rm -e DATABASE_URL=postgresql://guardian:guardian-local-only@db:5432/guardian_test loader   # 빈 DB → 스키마+시드
cd server && TEST_DATABASE_URL=postgresql://guardian:guardian-local-only@localhost:5433/guardian_test .venv/bin/python -m pytest -q
cd server/tools && python3 validate.py            # 명세(spec/openapi.yaml) ↔ 목업(mock/) 검증
```

## 6. 다음 단계에서 바꿀 곳

- A4 (재난 확장): `risk/engine.py` 에 호우(AWS 3·12시간 누적, 1·2번)·강풍·태풍·산사태·미세먼지·자외선 판정 추가, 시나리오 추가
- A5 (경고): `/user`, `/device-token`, `/alerts` 를 users·user_devices·user_alerts 로 → `routers/user.py`, `routers/alerts.py`
- A7 이후: 위험지역 고정 영역은 산사태 취약지역만 사용 (침수·해안 영역 레이어는 제거, 침수는 실시간 판정 영역 risk_areas). 새 정적 데이터는 `db/init/07_*.sql` 로 추가 → loader 가 자동 포함. route 서비스가 임시 GeoJSON 대신 hazard_zones·manholes 를 읽도록 B 와 합의
- B: `/api/chat` 은 ai 서비스, `/api/route` 는 route 서비스가 실제 구현 — 여기 `/api/v1/chat`·`/api/v1/route` 목업은 앱 개발용 (Caddy 경로 정리 시 합의)

## 자료 신선도 규칙 (`risk/freshness.py`)
- **표시**: 수집이 실패해도 가장 최근 성공값을 보여 줌. 지도 레이어 `stations` 에 `age_min`, `age_label`("14:10 기준 · 50분 전 자료"), `stale` 포함 → 앱·Agent 는 stale 이면 "오래된 자료"로 안내
- **판단**: 유효 시간 안의 값만 (수위계 40분 · 대기 60분 · 자외선 90분 · AWS 30분 · 초단기실황 격자 90분). 없으면 `FALLBACK` 순서로 대체 출처(AWS 816 → 격자 105,94 → 106,94), 그것도 없으면 **판단 불가(unknown)** — '정상'으로 내리지 않음
- 호우·강풍 판정(A4)은 `judge_source(metric, latest)` 로 출처를 고른 뒤 `risk_rules` 기준 적용. 순간풍속(wind_gust)은 AWS 에만 있어 없으면 평균풍속 기준만

## 긴급재난문자 (`safety24.disaster_messages`)
- 재난안전데이터공유플랫폼 `DSSP-IF-00247`, 키 `SAFETY24_API_KEY`(또는 dt_config `SAFETYDATA_KEY`). **등록된 IP 에서만 호출 가능** → 배포 VM 고정 IP 를 플랫폼에 추가 등록
- 2분 주기 (일일 한도 1,000회 → 720회/일). 어제 날짜부터 `rgnNm=포항` 조회, `SN` 기준 upsert
