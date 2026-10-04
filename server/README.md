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
    users.py           사용자 정보 (users·user_profiles·user_places·emergency_contacts·user_devices)
    incidents.py       대피 상황 조회 (방재단 화면 · 내 대피 확인 카드)
    households.py      취약 가구 (A13) — 본인 등록 · 대리 등록 · 동의 기록(버전) · 생활지원사 담당 범위
    schemas.py         요청 본문 모델 (spec/openapi.yaml 과 같은 제약)
    routers/           system · user · dashboard · risk · alerts · admin · internal   (대화는 ai, 경로는 route 서비스)
  collector/           수집기 (collector 서비스 — 같은 이미지, `python -m collector`)
    jobs.py            작업 16개 정의 (호출 → 변환 → 적재 → ingest_runs)
    fetch.py           live 호출 / replay(저장 원문) · 기상청 발표시각 계산
    store.py           DB upsert
    scheduler.py       APScheduler (Asia/Seoul)
    converters/        tools/ 변환기 사본 (이후 수정은 여기서)
  loader/              정적 데이터 적재 (A7) — db/init 스키마·시드 적용, 재실행 안전 (docker compose run --rm loader)
  risk/                판정 엔진 (A3)
    engine.py          최신 관측값 + risk_rules → risk_assessments 동기화
    queries.py         /risk (좌표), /risk/areas (영역 GeoJSON)
    simulate.py        시연 시나리오 (모의 관측값 주입 → 판정 → 선제 경고까지)
  alerts/              선제 경고 (A5) — 판정·재난문자 → 대상 사용자 → user_alerts · care.incidents → FCM
    policy.py          경고 종류 (대피 확인 / 일반 경고) 판단 규칙
    messages.py        경고 문구 템플릿 (B4 메시지 함수로 교체할 자리)
    dispatch.py        경고 생성 (수집기 risk.alerts · GET /alerts 즉시 판정)
    fcm.py             FCM 발송 (명세 FcmPayload)
    evacuation.py      대피 확인 (A12) — 응답 기록 · 재알림 · 방재단 이관 (시간 규칙)
  spec/openapi.yaml    API 명세 v0.3 — api·ai·route 3개 서비스 규약 (https://editor.swagger.io 에 붙여넣으면 문서)
  mock/                목업 응답 JSON · mock/external = 원천 API 저장 원문 (replay·테스트용)
  docs/spec-v0.3.md    v0.3 데이터 구조·통신 규약 (역할·취약 가구·대피 확인·방재단, 2026-10-03 확정 사항)
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
- **스키마 추가분(`01m_*.sql`, v0.3~)** 은 loader 가 매번 먼저 적용한다 (IF NOT EXISTS) → 볼륨 초기화 없이 `docker compose run --rm loader` 한 번이면 된다

### 정적 데이터 적재 — loader (A7)

```bash
docker compose run --rm loader              # 01m 스키마 추가분 · 02 판단 기준·관측소·맨홀 · 03 산사태 · 04 행동요령 · 05 대피소 · 06 응급의료 · 09 산사태 위험지도
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
| `risk.alerts` 선제 경고 (A5) | 10분 (3·13·23…분, 판정 직후) | user_alerts · care.incidents (+ FCM) | 30분 |
| `risk.evac_followup` 대피 확인 재알림·이관 (A12) | 1분 (2분 간격 재알림을 지키려고) | care.incident_targets (+ FCM) — ingest_runs 하루 1,440행 | 10분 |

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
| `GET /dashboard/layers/{shelters,medical,manholes}` | **실데이터** — 대피소(산사태 때 비추천 `unsuitable_for` 포함)·의료시설(응급실 가용병상 `er`)·맨홀 |
| `GET /hotlines` | **실데이터** — 긴급 전화 (public_hotlines) |
| `POST /user/role`, `POST /internal/invites` | **실데이터** — 초대 코드 발급·확인 → users.role (dev 모드는 `DEMO-RESPONDER` 등도 허용) |
| `/user`, `/user/places*`, `/user/contacts*`, `/user/checklist/*`, `/device-token` | **실데이터** (A5) — 첫 실행 `POST /user` 로 등록 (다른 `/user*` 는 등록 전 404) |
| `GET /alerts`, `POST /alerts/{id}/read` | **실데이터** (A5) — lat/lng 를 보내면 기기 위치 갱신 + 그 사용자 즉시 경고 판정 |
| `POST /alerts/{id}/response` | **실데이터** (A12) — 대상 상태 + 이력(evacuation_responses), 도움 필요는 즉시 이관, 종료된 상황 409 |
| `/admin/overview`, `/admin/incidents` (목록·수동 시작), `/{id}`, `/{id}/map`, `PATCH /{id}/targets/{tid}`, `/{id}/close` | **실데이터** (A12) — 생활지원사는 담당 가구만, 시작·종료는 방재단·관리자만 |
| `GET /dashboard` | **실데이터** (2026-10-05, `app/widgets.py`) — 위험 판정·머리 배너·장소별 위험·가까운 대피소 + 위젯: 특보·강수/바람(구룡포 AWS 6시간)·수위(포항 DT)·파고(단기예보 WAV)·단기예보·태풍(실황+예측)·재난문자·자외선/미세먼지. 자료 없으면 `{available:false, reason}` |
| `GET /support-programs` | **실데이터** — 복구·지원 제도 (`support_programs`) |
| `/user/household` (GET·PUT·DELETE), `/admin/households*` | **실데이터** (A13) — 동의 없으면 422·저장 안 함, 철회 = 삭제, 생활지원사는 담당 가구만(남의 가구 404), 주민은 /admin 403 |
| `POST /admin/incidents/{id}/targets/{tid}/visits` | **실데이터** (A14) — 등록 가구·앱 사용자 모두, 방문 결과에 따라 상태 변경, 종료된 상황 409 |
| 그 외 | 목업 (`X-Mock: true`) — 요청 검증·인증·권한은 실제와 동일. 방재단 화면은 `Bearer dev:responder-1` |

대화(`/api/chat`)는 ai 서비스, 경로(`/api/route`)는 route 서비스 — v0.3 에서 이 서버의 목업 `/chat`·`/voice`·`/route` 는 삭제했다.

### 침수 판정 (A3)

- 입력: 포항 DT 수위계(맨홀 3·지표면 5·하천 1)·강우량계 1의 최신값 (수집 40분 이내)
- 기준: DB `risk_rules` 를 읽어 적용 — 9번(지표면 침수심 ≥ 150mm, 반경 150m), 21~24번(수위계 DT 등급 2~5, 반경 100/150/300/500m), 25~28번(강우량계 DT 등급 2~5 → 구룡포읍 반경 4km)
- 관측소마다 가장 높은 단계 1개. 같은 단계면 15cm 침수심 기준을 우선 (근거 문장이 구체적)
- `risk_assessments`: 같은 판정이 이어지면 **같은 행(area_id) 유지**, 단계가 바뀌면 이전 행을 닫고 새 행, 정상이면 닫음.
  수집이 끊긴 관측소의 영역은 3시간 유지 (끊겼다고 '안전'으로 보이지 않게). `/risk` 의 `data_stale` 로 지연 표시
- `/risk` 의 `items[].location` 은 위험의 **원인 관측소** 위치 (조회 좌표 아님)

### 선제 경고 (A5)

| 경고 | 조건 (2026-10-03 결정) | 앱 |
|---|---|---|
| **대피 확인** (`response_required`, care.incidents) | 침수·호우·강풍·태풍·산사태 **경보(warning) 이상** · 재난문자 대피 지시 + '구룡포' 언급 (구룡포읍 반경 4km 전체) | 버튼 3개, FCM `kind=evacuation` |
| **일반 경고** | 그 밖의 **주의(advisory) 이상** (위 5종 주의, 미세먼지·초미세먼지·자외선·풍랑 등) | FCM `kind=alert` |
| 없음 | 관심·정상 | |

- 대상: 영역 안 **현재 위치**(60분 이내, `GET /alerts?lat&lng`) 또는 **알림 켠 등록 장소**. 사용자당 재난별 가장 높은 단계 1건 (같은 단계면 원인 관측소가 가까운 것)
- **침수·호우는 묶음**: 둘 중 하나라도 대피 확인이면 1건만 (높은 단계, 같으면 침수) — 나머지는 본문에 "호우 경보도 함께 발효 중입니다."
- 같은 판정은 다시 보내지 않음 (`user_alerts.dedupe_key = ra:<판정 id>` / `msg:<문자 id>`). 단계가 오르면 새 경고
- 대피 상황(care.incidents)은 판정 1건당 1개. 판정이 닫히면 같은 재난의 새 경보로 이어 붙이거나 종료 (FCM `incident_closed`). 재난문자 대피 상황은 6시간 뒤 종료. 영역 안 등록 가구도 대상(incident_targets)에 넣음
- 문구는 템플릿 (`alerts/messages.py`): 판정 근거 + 행동요령 한 문장 + 사용자 사정(고령·보행 불편·어업/선박·관광객) — B4 메시지 함수가 나오면 `compose()` 만 교체
- FCM: `FIREBASE_CREDENTIALS` 서비스 계정이 있으면 발송 (collector 컨테이너에도 `secrets/` 마운트). 없으면 발송만 건너뛰고 경고는 폴링으로 전달. 만료 토큰은 `fcm_token` 을 비움

### 대피 확인 (A12)

| 상태 | 서버가 하는 일 (`alerts/evacuation.py`, 1분마다) |
|---|---|
| 미응답 | 경고 후 **2분마다 재알림**(FCM `reminder`), **10분 뒤 방재단 이관**(FCM `escalation`, 이후 재알림 없음) |
| 도움 필요 | 응답 즉시 이관 (이미 이관됐어도 다시) — 위치 필수 |
| 대피 중 | **10분마다 재확인** "대피소에 도착하셨나요?" (이관 없음, 2026-10-04 결정) |
| 대피 완료 | 끝 |

- 응답 수단: 알림 버튼·대시보드·음성(B12)·방재단 대신 기록 모두 `care.evacuation_responses` 에 이력. 앱 사용자 본인 등록 가구도 같은 상황 대상이면 같은 상태로
- 이관 받는 사람: 역할 responder·admin 기기 전체 + 그 가구 담당 생활지원사. 앱 없는 등록 가구는 알림 없이 방재단 목록에만
- 방재단이 종료한 자동 상황은 같은 판정이 계속돼도 다시 열지 않음 (일반 경고로만). 수동 시작은 원(중심·반경) 또는 GeoJSON 영역 → 영역 안 사용자에게 대피 확인 경고 ("방재단 안내: …")
- 장소를 등록·수정하면 그 사용자만 즉시 경고 판정 (진행 중 경보 영역 안 집 → 바로 대피 확인)

### 장소 등록 (주소·좌표)

- `POST /user/places` 는 도로명 주소(`address`)·좌표(`location`) 중 하나 이상. 좌표가 있으면 그대로 쓰고(카카오 호출 없음), 주소만 오면 서버가 카카오로 도로명 주소·좌표 변환 — `KAKAO_REST_KEY` 가 없으면 주소만 보낸 요청은 503
- 지번만 있는 집·항구, 지도에서 찍기·현재 위치(GPS)로 등록할 때는 좌표를 보낸다 (2026-10-04 결정, C 와 합의)
- 숙소(`lodging`)만 있고 집이 없으면 관광객 — 집 등록을 요구하지 않고, 대피 확인 경고에 관광객 안내 문장이 붙는다 (사용자 유형 입력 대신)

### 방문 기록 (A14)

- 대상: 등록 가구 + 가구 등록 없는 앱 사용자(도움 요청한 사람 등) — `visit_logs.household_id` 는 선택, 앱 사용자는 `target_id` 로 연결 (`01m_v0_5_visits.sql`, 2026-10-04 결정)
- 방문 후 상태: 함께 대피·이송·이미 대피 → 대피 완료 / 부재·거부·기타 → **상태 그대로, 기록만** (대상 `last_visit` 으로 다시 갈 곳이 보임) / `status_after` 를 보내면 그 값
- 집계: 대피 상황 `summary.visited`(방문한 대상 수)·`unvisited_need_help`(도움 필요인데 아직 아무도 안 간 대상 수). 가구 상세에 최근 방문 5건

### 취약 가구·민감정보 (A13)

- 동의: 본인 등록은 앱 동의(`consent: true`), 대리 등록은 서면·구두 확인(`consent_method`·`consent_by`). 일시·방법·동의자·**동의서 버전**(`households.CONSENT_VERSION`, 지금 v1) 저장 — 문구가 바뀌면 버전을 올린다
- 동의 철회 = 가구 삭제 (대피 대상·방문 기록도 함께). 대리 등록 가구에 연결만 된 주민이 철회하면 연결만 끊음
- 건강 정보(혈액형·병력 메모)는 `care.user_health` — AI 읽기 전용 계정은 못 읽음 (`01m_v0_4_households.sql` 이 기존 값을 옮기고 public 컬럼 삭제). `/user` 응답 형식은 같음
- 시연용 가상 가구: `/internal/simulate` `demo_households` (5곳, "[시연] …", 침수 경보 영역 2곳·산사태 1등급 비탈 1곳) / `demo_households_clear`. `clear` 는 가구를 지우지 않음

### 시연 시나리오

```bash
T=$(grep '^API_INTERNAL_TOKEN=' .env | cut -d= -f2)      # dev 모드에서 비워 두면 헤더 없이도 됨
curl -X POST localhost:8000/api/v1/internal/simulate -H "X-Internal-Token: $T" -H 'Content-Type: application/json' -d '{"scenario":"heavy_rain_flood"}'
curl "localhost:8000/api/v1/risk?lat=35.99069&lng=129.556057"      # 구룡포환승센터 → 침수 경보 230mm
# 선제 경고: 사용자 등록 → 집 등록(환승센터) → 시나리오 실행 → 폴링하면 대피 확인 경고 (시나리오가 판정·경고를 바로 실행)
H='Authorization: Bearer dev:demo'
curl -X POST localhost:8000/api/v1/user -H "$H" -H 'Content-Type: application/json' -d '{"birth_year":1950,"walking_ability":"limited"}'
curl -X POST localhost:8000/api/v1/user/places -H "$H" -H 'Content-Type: application/json' -d '{"place_type":"home","label":"우리집","location":{"lat":35.99069,"lng":129.556057}}'   # 좌표 또는 도로명 주소(서버가 카카오로 변환, KAKAO_REST_KEY 필요)
curl -H "$H" localhost:8000/api/v1/alerts                             # 침수 경보 대피 확인 1건(호우 경보 함께 표기), mode=emergency
curl -X POST localhost:8000/api/v1/internal/simulate -H "X-Internal-Token: $T" -H 'Content-Type: application/json' -d '{"scenario":"clear"}'
```
모의값은 `observations.quality='simulated'` 로 저장되고 6시간 동안 실측보다 우선 (판정·지도 모두). `clear` 로 삭제.
배포 서버에서는 `X-Internal-Token` 헤더 필요.

목업 편의 기능: `GET /dashboard?...&scenario=emergency` 로 재난 모드 화면.

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
cd server/tools && python3 validate.py            # 명세(spec/openapi.yaml) ↔ 목업(mock/) 검증 (pytest 의 tests/test_spec.py 와 같은 내용)
```

## 6. 다음 단계에서 바꿀 곳

- A4 (재난 확장): `risk/engine.py` 에 호우(AWS 3·12시간 누적, 1·2번)·강풍·태풍·산사태·미세먼지·자외선 판정 추가, 시나리오 추가
- A5 (경고) 완료: 남은 것 — 실제 기기로 FCM 수신 확인(서비스 계정 키 필요), B4 메시지 함수 연결(`alerts/messages.compose`)
- A13 (취약 가구)·A14 (방문 기록) 완료: 남은 것 — B13 우선순위가 가구 사정(needs)·산사태 위치·방문 결과를 점수에 반영 (`incident_targets.priority_*`)
- A12 (대피 확인) 완료: 남은 것 — 재알림·이관 FCM 실기기 확인 (A9), B13 우선순위 점수(`incident_targets.priority_*`) 연결
- A12·A13·A14 (대피 응답·취약 가구·방문): `routers/alerts.py`(response), `routers/admin.py`, `routers/user.py`(household) 를 care 스키마로 — 규약은 `docs/spec-v0.3.md`
- A7 이후: 위험지역 고정 영역은 산사태 취약지역만 사용 (침수·해안 영역 레이어는 제거, 침수는 실시간 판정 영역 risk_areas). 새 정적 데이터는 `db/init/1x_*.sql` 로 추가 → loader 가 자동 포함 (스키마 추가분은 `01m_*.sql`, IF NOT EXISTS 로). route 서비스가 임시 GeoJSON 대신 hazard_zones·manholes 를 읽도록 B 와 합의
- B: `/api/chat` 은 ai 서비스, `/api/route` 는 route 서비스가 실제 구현 (형식은 spec/openapi.yaml 의 ai·route 태그)

## 자료 신선도 규칙 (`risk/freshness.py`)
- **표시**: 수집이 실패해도 가장 최근 성공값을 보여 줌. 지도 레이어 `stations` 에 `age_min`, `age_label`("14:10 기준 · 50분 전 자료"), `stale` 포함 → 앱·Agent 는 stale 이면 "오래된 자료"로 안내
- **판단**: 유효 시간 안의 값만 (수위계 40분 · 대기 60분 · 자외선 90분 · AWS 30분 · 초단기실황 격자 90분). 없으면 `FALLBACK` 순서로 대체 출처(AWS 816 → 격자 105,94 → 106,94), 그것도 없으면 **판단 불가(unknown)** — '정상'으로 내리지 않음
- 호우·강풍 판정(A4)은 `judge_source(metric, latest)` 로 출처를 고른 뒤 `risk_rules` 기준 적용. 순간풍속(wind_gust)은 AWS 에만 있어 없으면 평균풍속 기준만

## 긴급재난문자 (`safety24.disaster_messages`)
- 재난안전데이터공유플랫폼 `DSSP-IF-00247`, 키 `SAFETY24_API_KEY`(또는 dt_config `SAFETYDATA_KEY`). **등록된 IP 에서만 호출 가능** → 배포 VM 고정 IP 를 플랫폼에 추가 등록
- 2분 주기 (일일 한도 1,000회 → 720회/일). 어제 날짜부터 `rgnNm=포항` 조회, `SN` 기준 upsert
