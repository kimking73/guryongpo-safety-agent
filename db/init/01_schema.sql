-- =====================================================================
--  구룡가디언 (구룡포 재난 지킴이) — DB 스키마 v0.1 (1주차)
--  PostgreSQL 16 + PostGIS 3
--  좌표계: 모든 geometry는 WGS84 (EPSG:4326), 좌표 순서 [경도, 위도]
--  시간: 모든 시각은 timestamptz (클라이언트 응답은 +09:00 KST)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- 0. 공통 ENUM
-- ---------------------------------------------------------------------
CREATE TYPE user_type        AS ENUM ('resident', 'tourist', 'worker');          -- 주민 / 관광객 / 구룡포 근무자
CREATE TYPE mobility_mode    AS ENUM ('walk', 'car', 'bicycle', 'public_transit', 'wheelchair');
CREATE TYPE walking_ability  AS ENUM ('normal', 'limited', 'unable');            -- 보행능력
CREATE TYPE place_type       AS ENUM ('home', 'work', 'frequent', 'lodging');     -- 거주지 / 직장 / 자주 가는 곳 / 숙소(관광객)

-- 위험 판단 대상 재난 (4대 재난 + 생활안전 + 해상)
CREATE TYPE hazard_type AS ENUM (
  'landslide',     -- 산사태
  'heavy_rain',    -- 호우
  'flood',         -- 침수
  'strong_wind',   -- 강풍
  'typhoon',       -- 태풍
  'high_seas',     -- 풍랑 (어업 종사자용)
  'fine_dust',     -- 미세먼지 PM10
  'ultrafine_dust',-- 초미세먼지 PM2.5
  'uv'             -- 자외선
);

-- 위험 단계: 0 정상 → 4 최고. 특보는 advisory(주의보)/warning(경보),
-- 자외선은 low/moderate/high/very_high/extreme 을 label 로 별도 보관
CREATE TYPE risk_level AS ENUM ('normal', 'watch', 'advisory', 'warning', 'critical');

CREATE TYPE phase_type   AS ENUM ('before', 'during', 'after');                 -- 재난 전/중/후
CREATE TYPE chat_role    AS ENUM ('user', 'assistant', 'system', 'tool');
CREATE TYPE verify_state AS ENUM ('passed', 'retried', 'failed', 'skipped');    -- 환각/의도 검증 결과

-- ---------------------------------------------------------------------
-- 1. 사용자
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  firebase_uid    text UNIQUE NOT NULL,              -- Firebase 익명 로그인 uid (인증은 Firebase가 담당, 비밀번호 저장 안 함)
  is_anonymous    boolean     NOT NULL DEFAULT true, -- 계정 연결(linkWithCredential) 시 false
  nickname        text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_active_at  timestamptz
);

-- 맞춤형 경고/경로 가중치에 쓰이는 인적사항 (users 와 1:1)
CREATE TABLE user_profiles (
  user_id            uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  -- 기본 정보 (필수 수집)
  user_type          user_type,
  birth_year         smallint CHECK (birth_year BETWEEN 1900 AND 2100),
  mobility           mobility_mode,
  -- 부가 정보 (필요 시 수집)
  occupation         text,                           -- 'fisher', 'merchant', 'farmer', 'office', 'student', ...
  owns_vessel        boolean NOT NULL DEFAULT false, -- 선박 보유 (수산업 맞춤 정보)
  walking_ability    walking_ability NOT NULL DEFAULT 'normal',
  vision_impaired    boolean NOT NULL DEFAULT false,
  hearing_impaired   boolean NOT NULL DEFAULT false,
  blood_type         text CHECK (blood_type IN ('A+','A-','B+','B-','O+','O-','AB+','AB-')),
  has_dependents     boolean NOT NULL DEFAULT false, -- 보호가 필요한 동반자(영유아/노약자/반려동물)
  dependents_note    text,
  medical_note       text,                           -- 119 전달용 (지병/복용약 등, 사용자 자유기재)
  prefers_voice      boolean NOT NULL DEFAULT false,
  language           text NOT NULL DEFAULT 'ko',
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_places (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  place_type  place_type NOT NULL,
  label       text NOT NULL,                         -- '우리집', '구룡포항 3부두'
  address     text,
  geom        geometry(Point, 4326) NOT NULL,
  notify      boolean NOT NULL DEFAULT true,         -- 이 장소 위험 시 알림 여부
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_user_places_user ON user_places(user_id);
CREATE INDEX idx_user_places_geom ON user_places USING gist(geom);

CREATE TABLE emergency_contacts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  relation    text,
  phone       text NOT NULL,
  priority    smallint NOT NULL DEFAULT 1
);
CREATE INDEX idx_emergency_contacts_user ON emergency_contacts(user_id);

-- 기기별 푸시 토큰 + 마지막 위치 (선제적 경고의 대상 판정에 사용)
CREATE TABLE user_devices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform          text NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
  fcm_token         text UNIQUE,                     -- POST /device-token (NULL = 푸시 해제, 폴링만)
  last_location     geometry(Point, 4326),
  last_location_at  timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_user_devices_user ON user_devices(user_id);
CREATE INDEX idx_user_devices_loc  ON user_devices USING gist(last_location);

-- ---------------------------------------------------------------------
-- 2. 데이터 수집 (데이터 수집 프로세스가 적재)
-- ---------------------------------------------------------------------
CREATE TABLE data_sources (
  code        text PRIMARY KEY,          -- 'pohang_dt', 'kma', 'safety24', 'safemap', 'datagokr', 'osm', 'ngii_dem'
  name        text NOT NULL,
  provider    text,
  base_url    text,
  note        text
);

-- 수집 실행 이력 (대시보드의 '마지막 갱신 시각', 장애 추적)
CREATE TABLE ingest_runs (
  id           bigserial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  job          text NOT NULL,             -- 'water_level', 'asos', 'vilage_fcst', 'wrn', 'disaster_msg', ...
  started_at   timestamptz NOT NULL DEFAULT now(),
  finished_at  timestamptz,
  status       text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'success', 'failed')),
  row_count    integer,
  error        text
);
CREATE INDEX idx_ingest_runs_job ON ingest_runs(source_code, job, started_at DESC);

-- 관측소 (수위계, 기상관측소, 대기측정소, 자외선, 파고부이 등)
CREATE TABLE stations (
  id           serial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  external_id  text NOT NULL,             -- 원천 시스템의 관측소 ID (포항 DT: 응답의 id)
  name         text NOT NULL,             -- 포항 DT: '구룡포환승센터_지표면 수위계'
  -- 포항 DT sensorType: HOLE → manhole(스마트맨홀) / ROAD → road_flood(지표면 수위계)
  --                     RIVER → river_level(하천 수위계) / RAIN → rain_gauge(강우량계)
  kind         text NOT NULL CHECK (kind IN ('manhole', 'road_flood', 'river_level', 'rain_gauge',
                                             'weather', 'air', 'uv', 'wave', 'tide')),
  address      text,
  geom         geometry(Point, 4326) NOT NULL,
  is_mountain  boolean NOT NULL DEFAULT false, -- 산지 여부 (강풍 기준이 다름)
  is_active    boolean NOT NULL DEFAULT true,
  meta         jsonb NOT NULL DEFAULT '{}',   -- 포항 DT: {"eui": "50F8A5FFFE0EF54B", "sensor_type": "ROAD"}
  UNIQUE (source_code, external_id)
);
CREATE INDEX idx_stations_geom ON stations USING gist(geom);

-- 실시간 관측값 (long format: 관측소 × 지표 × 시각)
-- metric 예시: rain_1h(mm), rain_3h, rain_12h, wind_speed(m/s), wind_gust, wind_dir(deg),
--             temp(°C), humidity(%), wave_height(m), pm10(㎍/㎥), pm25, uv_index,
--             포항 DT: manhole_level(HOLE, mm · 판단엔 미사용, level 만 사용), flood_depth(ROAD, mm), river_level(RIVER, mm), rain_1h(RAIN, mm)
--             포항 DT 대기(kind=air, external_id='air_<devId>'): pm10, pm25, wind_speed·wind_dir(참고), temp, humidity, o3, no2, so2, co, voc, h2s, nh3, hcho, co2(%), odor, battery
--               → observed_at = 응답 logDateTime (원천 측정 시각). 위험 판단은 60분 이내 값만
--             기상청 초단기실황(kind=weather, source=kma, external_id='grid_<nx>_<ny>'): temp, rain_1h, humidity, wind_speed, wind_dir, precip_type
--               → observed_at = base_date+base_time (정시). 순간풍속(wind_gust) 없음 → 강풍 순간풍속 기준은 AWS 필요
--             기상청 AWS 시간통계(kind=weather, source=kma, external_id='aws_<지점번호>'): wind_speed(정시 10분 평균), wind_dir, wind_gust(60분 최대순간풍속)
--             포항 DT 자외선(kind=uv, external_id='uv_latest'): uv_index — 구룡포 전역 값 1개, observed_at = 응답 dateTime
-- 포항 DT '수위계' 응답에는 측정 시각이 없고 언제 측정되는지도 알 수 없음(약 1시간 주기 갱신)
--   → observed_at = 우리 서버가 값을 받아온 '수집 시각'. 10분마다 수집한 스냅샷을 모두 저장
CREATE TABLE observations (
  station_id   integer     NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
  metric       text        NOT NULL,
  observed_at  timestamptz NOT NULL,
  value        double precision NOT NULL,
  unit         text        NOT NULL,
  source_level smallint,                  -- 원천 위험 등급 (포항 DT level: 1 정상 / 2 보통 / 3 주의 / 4 경보 / 5 위험)
  quality      text,                      -- 원천 품질 플래그
  ingest_run_id bigint REFERENCES ingest_runs(id),
  PRIMARY KEY (station_id, metric, observed_at)
);
CREATE INDEX idx_observations_latest ON observations(metric, observed_at DESC);
-- 관측소×지표별 최신값 조회 (v_latest_observations, 지도 stations 레이어) — 3주 누적 시 정렬 비용 방지
CREATE INDEX idx_observations_station_latest ON observations(station_id, metric, observed_at DESC);

-- 관측소별 지표 최신값 (대시보드/Agent 조회 최적화)
CREATE VIEW v_latest_observations AS
SELECT DISTINCT ON (o.station_id, o.metric)
       o.station_id, s.name AS station_name, s.kind, s.geom,
       o.metric, o.value, o.unit, o.source_level, o.observed_at
FROM observations o
JOIN stations s ON s.id = o.station_id
WHERE s.is_active
ORDER BY o.station_id, o.metric, o.observed_at DESC;

-- 기상청 단기/중기 예보 (격자 or 지역코드)
-- category: POP(강수확률), PTY(강수형태), PCP(1시간강수량), TMP(기온), WSD(풍속), VEC(풍향), SKY, REH ...
CREATE TABLE forecasts (
  id           bigserial PRIMARY KEY,
  kind         text NOT NULL CHECK (kind IN ('ultra_short', 'short', 'mid')),
  grid_nx      smallint,                  -- 단기예보 격자 X (구룡포 위경도 → 기상청 격자 변환값)
  grid_ny      smallint,
  region_code  text,                      -- 중기예보 구역 코드
  base_time    timestamptz NOT NULL,      -- 발표 시각
  fcst_time    timestamptz NOT NULL,      -- 예보 대상 시각
  category     text NOT NULL,
  value        text NOT NULL,             -- 기상청 원문 값 (예: '강수없음', '1.0mm')
  value_num    double precision,          -- 수치 변환값 (가능할 때)
  -- NULLS NOT DISTINCT (PostgreSQL 15+): 동네예보는 region_code, 중기예보는 grid 가 NULL 이어도 중복 방지
  UNIQUE NULLS NOT DISTINCT (kind, grid_nx, grid_ny, region_code, base_time, fcst_time, category)
);
-- category (기상청 원문 코드): POP 강수확률 · PTY 강수형태(0없음 1비 2비/눈 3눈 4소나기 5빗방울 6빗방울눈날림 7눈날림)
--   PCP/RN1 1시간 강수량(범주 문자열 → value_num 은 하한값, '1mm 미만'=0.5) · SNO 신적설 · SKY 하늘(1맑음 3구름많음 4흐림)
--   TMP/T1H 기온 · TMN/TMX 최저/최고 · REH 습도 · WSD 풍속 · VEC 풍향 · UUU/VVV 바람성분 · WAV 파고(m) · LGT 낙뢰
-- 구룡포 격자: (105,94) 읍 중심, (106,94) 구룡포항  — tools/kma_vilage.py
CREATE INDEX idx_forecasts_grid ON forecasts(kind, grid_nx, grid_ny, fcst_time);

-- 예보 대상 시각별 가장 최근 발표값 (대시보드·Agent 조회용)
CREATE VIEW v_latest_forecasts AS
SELECT DISTINCT ON (kind, grid_nx, grid_ny, region_code, fcst_time, category) *
FROM forecasts
ORDER BY kind, grid_nx, grid_ny, region_code, fcst_time, category, base_time DESC;
CREATE INDEX idx_forecasts_lookup ON forecasts(kind, fcst_time, category);

-- 기상특보 (호우/강풍/태풍/풍랑/폭풍해일 등)
CREATE TABLE weather_warnings (
  id             bigserial PRIMARY KEY,
  source_code    text NOT NULL REFERENCES data_sources(code),
  external_id    text,                    -- 특보 발표번호 등
  hazard         hazard_type NOT NULL,
  level          risk_level  NOT NULL CHECK (level IN ('watch', 'advisory', 'warning')),  -- watch = 예비특보
  region_code    text,
  region_name    text NOT NULL,           -- '포항시', '경북남부앞바다' ...
  area           geometry(MultiPolygon, 4326),
  issued_at      timestamptz NOT NULL,
  effective_at   timestamptz,
  released_at    timestamptz,             -- 해제 시각 (NULL = 발효 중)
  headline       text,
  raw            jsonb NOT NULL DEFAULT '{}',
  UNIQUE (source_code, external_id, hazard, region_code)
);
CREATE INDEX idx_weather_warnings_active ON weather_warnings(hazard) WHERE released_at IS NULL;
CREATE INDEX idx_weather_warnings_area   ON weather_warnings USING gist(area);

-- 태풍 진로 (재난안전24 / 기상청)
CREATE TABLE typhoon_tracks (
  id               bigserial PRIMARY KEY,
  typhoon_code     text NOT NULL,         -- 연도2자리+번호 (예: 힌남노 '2211')
  name_ko          text,
  observed_at      timestamptz NOT NULL,  -- 분석시각(실황) 또는 예측시각 (원천 UTC → KST 저장)
  issued_at        timestamptz,           -- 이 값을 낸 분석(발표) 시각
  is_forecast      boolean NOT NULL DEFAULT false,
  geom             geometry(Point, 4326) NOT NULL,
  direction        text,                  -- 진행방향 16방위 (NNE 등)
  speed_kmh        real,
  central_pressure_hpa  smallint,
  max_wind_ms      real,
  radius_15ms_km   real,                  -- 강풍반경
  radius_25ms_km   real,                  -- 폭풍반경
  prob_radius_km   real,                  -- 70% 확률반경 (예측)
  location_text    text,                  -- '포항 북동쪽 약 60 km 부근 해상'
  UNIQUE (typhoon_code, observed_at, is_forecast)
);
CREATE INDEX idx_typhoon_tracks_geom ON typhoon_tracks USING gist(geom);

-- 재난문자 (재난안전24)
CREATE TABLE disaster_messages (
  id           bigserial PRIMARY KEY,
  external_id  text UNIQUE NOT NULL,
  sent_at      timestamptz NOT NULL,
  sender       text,                      -- '포항시', '행정안전부' ...
  region_name  text,
  category     text,                      -- '호우', '태풍', '산사태' ... (원문)
  hazard       hazard_type,               -- 매핑 가능하면 채움
  alert_class  text,                      -- '안전안내', '긴급재난', '위급재난'
  message      text NOT NULL,
  raw          jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX idx_disaster_messages_sent ON disaster_messages(sent_at DESC);

-- ---------------------------------------------------------------------
-- 3. 공간 정보 (정적/준정적)
-- ---------------------------------------------------------------------
CREATE TABLE shelters (
  id            serial PRIMARY KEY,
  source_code   text NOT NULL REFERENCES data_sources(code),
  external_id   text,
  name          text NOT NULL,
  shelter_types text[] NOT NULL,          -- {'flood','earthquake','tsunami','civil_defense','heat','cold'}
  address       text,
  capacity      integer,
  phone         text,
  is_indoor     boolean,
  is_accessible boolean,                  -- 휠체어 접근 가능
  is_open       boolean NOT NULL DEFAULT true,  -- (향후) 포항시 운영 현황 반영
  geom          geometry(Point, 4326) NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_code, external_id)
);
CREATE INDEX idx_shelters_geom ON shelters USING gist(geom);

CREATE TABLE medical_facilities (
  id           serial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  external_id  text,
  name         text NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('hospital', 'clinic', 'public_health', 'pharmacy', 'emergency_room')),
  address      text,
  phone        text,
  open_hours   jsonb,
  geom         geometry(Point, 4326) NOT NULL,
  meta         jsonb NOT NULL DEFAULT '{}',   -- 국립중앙의료원: {"er_phone": 응급실 직통, "emergency_class": 권역/지역응급의료센터·지역응급의료기관}
  UNIQUE (source_code, external_id)
);

-- 응급실 실시간 가용병상 (국립중앙의료원 getEmrrmRltmUsefulSckbdInfoInqire, 10분 주기) — "지금 받아 줄 수 있는 응급실" 안내
CREATE TABLE er_availability (
  facility_id    integer NOT NULL REFERENCES medical_facilities(id) ON DELETE CASCADE,
  observed_at    timestamptz NOT NULL,     -- 원천 입력시각 hvidate
  er_beds        integer,                  -- hvec 응급실 가용병상 (음수 = 과밀)
  surgery_rooms  integer,                  -- hvoc
  inpatient_beds integer,                  -- hvgc
  ambulance      boolean,                  -- hvamyn
  raw            jsonb NOT NULL DEFAULT '{}',
  PRIMARY KEY (facility_id, observed_at)
);
CREATE INDEX idx_medical_geom ON medical_facilities USING gist(geom);

-- 위험 지역 (산사태 위험지역, 침수 흔적/예상 지역, 해안 위험구역 등)
CREATE TABLE hazard_zones (
  id           serial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  external_id  text,
  hazard       hazard_type NOT NULL,      -- landslide / flood / high_seas(해안 위험) ...
  name         text,
  grade        text,                      -- 원천 등급 (예: 산사태 1~5등급)
  geom         geometry(MultiPolygon, 4326) NOT NULL,
  meta         jsonb NOT NULL DEFAULT '{}',
  UNIQUE (source_code, external_id)
);
CREATE INDEX idx_hazard_zones_geom ON hazard_zones USING gist(geom);

-- 맨홀 (침수 시 경로 회피)
CREATE TABLE manholes (
  id           serial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  external_id  text,
  kind         text,                      -- 우수/오수/합류
  geom         geometry(Point, 4326) NOT NULL,
  UNIQUE (source_code, external_id)
);
CREATE INDEX idx_manholes_geom ON manholes USING gist(geom);

-- ---------------------------------------------------------------------
-- 4. Risk engine
-- ---------------------------------------------------------------------
-- 판단 기준 테이블: 코드에 하드코딩하지 않고 DB로 관리 → Agent가 근거로 인용
CREATE TABLE risk_rules (
  id             serial PRIMARY KEY,
  hazard         hazard_type NOT NULL,
  level          risk_level  NOT NULL,
  label          text NOT NULL,           -- '호우주의보', '자외선 매우높음' ...
  metric         text,                    -- observations.metric 과 매칭 (NULL = 복합/공간 조건)
  operator       text CHECK (operator IN ('>=', '>', '<=', '<', 'between', 'within', 'composite')),
  threshold      double precision,
  threshold_max  double precision,        -- between 용 상한
  duration_min   integer,                 -- 지속 시간 조건 (분)
  condition      jsonb NOT NULL DEFAULT '{}', -- 복합 조건 (OR 그룹, 산지 여부 등)
  source_name    text NOT NULL,           -- 근거 출처 (환각 검증용)
  source_url     text,
  is_active      boolean NOT NULL DEFAULT true
);
CREATE INDEX idx_risk_rules_hazard ON risk_rules(hazard, level);

-- 위험 판단 결과 (주기 계산 → 지역 단위 위험 영역)
CREATE TABLE risk_assessments (
  id            bigserial PRIMARY KEY,
  hazard        hazard_type NOT NULL,
  level         risk_level  NOT NULL,
  label         text,
  area          geometry(MultiPolygon, 4326) NOT NULL, -- 영향 범위 (관측소 버퍼, 위험지역 등)
  rule_id       integer REFERENCES risk_rules(id),
  basis         jsonb NOT NULL DEFAULT '{}',  -- {"station_id":3,"metric":"rain_3h","value":72.5,"observed_at":"..."}
  valid_from    timestamptz NOT NULL DEFAULT now(),
  valid_to      timestamptz,                  -- NULL = 현재 유효
  computed_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_risk_assessments_active ON risk_assessments(hazard, level) WHERE valid_to IS NULL;
CREATE INDEX idx_risk_assessments_area   ON risk_assessments USING gist(area);

-- 사용자에게 발송된 경고
CREATE TABLE user_alerts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hazard          hazard_type NOT NULL,
  level           risk_level  NOT NULL,
  title           text NOT NULL,
  body            text NOT NULL,
  reason          jsonb NOT NULL DEFAULT '{}', -- 왜 이 사용자에게 보냈는지 (위치/직업/건강 등)
  assessment_id   bigint REFERENCES risk_assessments(id),
  warning_id      bigint REFERENCES weather_warnings(id),
  place_id        uuid REFERENCES user_places(id) ON DELETE SET NULL,
  location        geometry(Point, 4326),
  dedupe_key      text NOT NULL,               -- 같은 경고 중복 발송 방지: user+hazard+level+assessment
  created_at      timestamptz NOT NULL DEFAULT now(),
  pushed_at       timestamptz,                 -- FCM 발송 시각 (폴링으로도 동일 id 전달 → 앱이 중복 제거)
  read_at         timestamptz,
  UNIQUE (user_id, dedupe_key)
);
CREATE INDEX idx_user_alerts_user ON user_alerts(user_id, created_at DESC);

-- ---------------------------------------------------------------------
-- 5. 경로 안내 (GraphHopper 결과 로그 + 재탐색 기준)
-- ---------------------------------------------------------------------
CREATE TABLE route_requests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
  origin          geometry(Point, 4326) NOT NULL,
  destination     geometry(Point, 4326) NOT NULL,
  shelter_id      integer REFERENCES shelters(id),
  profile         text NOT NULL CHECK (profile IN ('fastest', 'safe', 'elderly', 'wheelchair', 'car')),
  avoid           jsonb NOT NULL DEFAULT '{}',   -- {"flood":true,"landslide":true,"manhole":true,"max_slope_pct":8}
  path            geometry(LineString, 4326),
  distance_m      real,
  duration_s      real,
  risk_summary    jsonb NOT NULL DEFAULT '{}',   -- 경로 상 남은 위험요소
  created_at      timestamptz NOT NULL DEFAULT now(),
  parent_id       uuid REFERENCES route_requests(id)   -- 재탐색 시 이전 경로
);
CREATE INDEX idx_route_requests_user ON route_requests(user_id, created_at DESC);

-- ---------------------------------------------------------------------
-- 6. 행동요령 / 체크리스트 / 지원제도 (Agent 답변의 근거 DB)
-- ---------------------------------------------------------------------
-- target 태그 예시: 'all','elderly','child','disabled','wheelchair','vision','hearing',
--                    'fisher','vessel_owner','coastal','farmer','tourist','resident','driver','pet_owner'
CREATE TABLE action_guides (
  id           serial PRIMARY KEY,
  hazard       hazard_type NOT NULL,
  phase        phase_type  NOT NULL,
  min_level    risk_level  NOT NULL DEFAULT 'normal', -- 이 단계 이상일 때 노출
  targets      text[] NOT NULL DEFAULT '{all}',
  priority     smallint NOT NULL DEFAULT 50,          -- 낮을수록 먼저 (행동 우선순위)
  title        text NOT NULL,
  content      text NOT NULL,
  voice_text   text,                                  -- 음성 안내용 짧은 문장
  source_name  text NOT NULL,                         -- 포항시 재난안전 / 국민재난안전포털 / 기상청
  source_url   text
);
CREATE INDEX idx_action_guides_lookup ON action_guides(hazard, phase, priority);
CREATE INDEX idx_action_guides_targets ON action_guides USING gin(targets);

CREATE TABLE checklist_items (
  id           serial PRIMARY KEY,
  hazard       hazard_type NOT NULL,
  phase        phase_type  NOT NULL,
  targets      text[] NOT NULL DEFAULT '{all}',
  sort_order   smallint NOT NULL DEFAULT 0,
  content      text NOT NULL,
  is_often_missed boolean NOT NULL DEFAULT false,     -- '놓치기 쉬운 항목' 강조
  source_name  text NOT NULL,
  source_url   text
);
CREATE INDEX idx_checklist_lookup ON checklist_items(hazard, phase, sort_order);

CREATE TABLE user_checklist_progress (
  user_id      uuid    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_id      integer NOT NULL REFERENCES checklist_items(id) ON DELETE CASCADE,
  checked_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, item_id)
);

-- 재난 후 보험·복구·법률 지원
-- 공공 긴급전화 (119 등 전국 공통 + 포항시·구룡포 기관) — 앱 긴급 버튼, Agent 답변 call_button
CREATE TABLE public_hotlines (
  id           serial PRIMARY KEY,
  name         text NOT NULL,                 -- '119 화재·구조·구급', '포항시 재난안전상황실'
  phone        text NOT NULL,
  scope        text NOT NULL CHECK (scope IN ('national', 'pohang', 'guryongpo')),
  hazards      hazard_type[] NOT NULL DEFAULT '{}',  -- 비어 있으면 전 재난 공통
  targets      text[] NOT NULL DEFAULT '{all}',      -- 'fisher' 등
  priority     smallint NOT NULL DEFAULT 50,          -- 낮을수록 먼저 노출
  note         text,
  source_name  text NOT NULL,
  source_url   text
);

CREATE TABLE support_programs (
  id             serial PRIMARY KEY,
  category       text NOT NULL CHECK (category IN ('insurance', 'recovery', 'legal', 'fishery', 'livelihood', 'medical')),
  hazards        hazard_type[] NOT NULL DEFAULT '{}',
  targets        text[] NOT NULL DEFAULT '{all}',
  name           text NOT NULL,
  summary        text NOT NULL,
  eligibility    text,
  how_to_apply   text,
  apply_period   text,
  department     text,                               -- 담당 부서
  contact        text,
  url            text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_support_programs_targets ON support_programs USING gin(targets);

-- ---------------------------------------------------------------------
-- 7. AI Agent 대화 (LangGraph)
-- ---------------------------------------------------------------------
CREATE TABLE chat_sessions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode        text NOT NULL DEFAULT 'text' CHECK (mode IN ('text', 'voice')),
  title       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_chat_sessions_user ON chat_sessions(user_id, updated_at DESC);

CREATE TABLE chat_messages (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id     uuid NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  role           chat_role NOT NULL,
  content        text NOT NULL,
  blocks         jsonb,                    -- 답변 다듬기 agent 결과: 표/차트/체크리스트/경로카드 등 구조화 블록
  audio_url      text,                     -- TTS 결과 (음성 모드)
  location       geometry(Point, 4326),    -- 질문 시점 사용자 위치
  grounding      jsonb NOT NULL DEFAULT '[]', -- 답변 근거: [{"table":"observations","id":...,"value":...}]
  verification   verify_state,             -- 환각/의도 검증 최종 결과
  latency_ms     integer,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_chat_messages_session ON chat_messages(session_id, created_at);

-- Agent 실행 추적 (관리자 → 전문 agent → 의도/환각 검증 → 다듬기, 재시도 루프 포함)
CREATE TABLE agent_runs (
  id           bigserial PRIMARY KEY,
  message_id   uuid NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE, -- assistant 메시지
  iteration    smallint NOT NULL DEFAULT 1,   -- 검증 실패로 재생성된 횟수
  agent        text NOT NULL CHECK (agent IN (
                 'supervisor', 'rain', 'flood', 'location_route', 'action',
                 'intent_check', 'hallucination_check', 'polish')),
  input        jsonb,
  output       jsonb,
  status       text NOT NULL CHECK (status IN ('ok', 'rejected', 'error')),
  feedback     text,                          -- 검증 agent가 반려한 사유
  latency_ms   integer,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_agent_runs_message ON agent_runs(message_id, iteration);

-- ---------------------------------------------------------------------
-- 8. 긴급 SOS
-- ---------------------------------------------------------------------
CREATE TABLE emergency_events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  location     geometry(Point, 4326),
  hazard       hazard_type,
  payload      jsonb NOT NULL,                -- 119/비상연락처에 전달한 요약 (위치·건강정보)
  notified     text[] NOT NULL DEFAULT '{}',  -- {'119','contact:<id>'}
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_emergency_events_user ON emergency_events(user_id, created_at DESC);
