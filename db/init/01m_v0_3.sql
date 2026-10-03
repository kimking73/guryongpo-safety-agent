-- =====================================================================
--  구룡가디언 — 스키마 v0.3 추가분 (2026-10-03, 명세 v0.3 과 함께 고정)
--  대상: 추가 기능 7종 중 A5 선제 경고 응답 · A12 대피 응답 · A13 취약 가구·동의·방재단 권한 · A14 방문 기록
--        · B11 해상 경로(항구) · B13 우선순위 결과 · C7 접근성 알림 설정
--
--  다시 실행해도 안전 (IF NOT EXISTS / duplicate_object 무시) — 이미 만든 DB 도 loader 가 매번 먼저 적용한다.
--    빈 DB:  docker 초기화가 00 → 01 → 01m → 02 … 순서로 실행
--    기존 DB: docker compose run --rm loader   (loader 가 01m_* 을 스키마 확인 전에 적용)
--
--  개인정보: 취약 가구·대피 응답·방문 기록은 public 이 아닌 care 스키마에 둔다.
--    AI 읽기 전용 계정(07_ai_readonly.sh)은 public 스키마에만 SELECT 권한이 있으므로 care 는 읽지 못한다.
--    B13 우선순위 계산은 A 서버 안에서 실행하고 결과(점수·근거)만 incident_targets 에 쓴다.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. ENUM
-- ---------------------------------------------------------------------
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('resident', 'responder', 'caregiver', 'admin');
  -- resident 주민(기본) / responder 자율방재단 / caregiver 독거노인 생활지원사 / admin 읍사무소 담당자·운영
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- 대피 상태. 버튼 문구: evacuated '대피 완료' / evacuating '대피 중' / need_help '도움 필요' (2026-10-03 확정)
  -- no_response = 아직 응답 없음 (초기값)
  CREATE TYPE evac_status AS ENUM ('no_response', 'evacuating', 'evacuated', 'need_help');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  -- 응답 수단: button 알림 버튼 / voice 음성 대피 확인(B12) / dashboard 앱 대시보드 / responder 방재단이 대신 기록 / auto 시스템
  CREATE TYPE response_via AS ENUM ('button', 'voice', 'dashboard', 'responder', 'auto');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------
-- 1. public 확장 (AI 도 읽어도 되는 정보만)
-- ---------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS role            user_role NOT NULL DEFAULT 'resident';
ALTER TABLE users ADD COLUMN IF NOT EXISTS role_granted_at timestamptz;

-- C7 접근성 알림 설정: {"tts": bool, "strong_vibration": bool, "screen_flash": bool, "large_text": bool}
-- 비어 있으면 서버가 vision_impaired → tts, hearing_impaired → strong_vibration + screen_flash 로 기본값을 채워 응답
ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS alert_prefs jsonb NOT NULL DEFAULT '{}';

-- A5·A12: 대피 확인이 필요한 경고 (3버튼) + 음성으로 읽어 줄 짧은 문장
ALTER TABLE user_alerts ADD COLUMN IF NOT EXISTS response_required boolean NOT NULL DEFAULT false;
ALTER TABLE user_alerts ADD COLUMN IF NOT EXISTS incident_id       uuid;      -- care.incidents.id (스키마 분리를 위해 FK 없음)
ALTER TABLE user_alerts ADD COLUMN IF NOT EXISTS tts_text          text;

-- B11 해상 → 최근접 항: 항구·접안 지점 (데이터는 B11 이 출처 확인 후 적재)
CREATE TABLE IF NOT EXISTS ports (
  id           serial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES data_sources(code),
  external_id  text,
  name         text NOT NULL,                       -- '구룡포항'
  kind         text NOT NULL CHECK (kind IN ('national_fishing', 'local_fishing', 'village_fishing', 'small_port', 'other')),
  berth        geometry(Point, 4326) NOT NULL,      -- 배를 댈 지점 (해상 구간의 도착점)
  land_point   geometry(Point, 4326) NOT NULL,      -- 육상 경로 출발점 (도로와 이어지는 지점 → /api/route origin)
  meta         jsonb NOT NULL DEFAULT '{}',
  UNIQUE (source_code, external_id)
);
CREATE INDEX IF NOT EXISTS idx_ports_berth ON ports USING gist(berth);

-- ---------------------------------------------------------------------
-- 2. care 스키마 — 민감정보 (A 서버 계정만 접근)
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS care;

-- 초대 코드 → 방재단·생활지원사·관리자 역할 (2026-10-03 확정: 초대 코드 입력 방식)
-- 코드 원문은 저장하지 않고 sha256 만 저장. 발급: POST /api/v1/internal/invites (원문은 응답에 한 번만)
CREATE TABLE IF NOT EXISTS care.invite_codes (
  id           serial PRIMARY KEY,
  code_hash    text UNIQUE NOT NULL,
  role         user_role NOT NULL CHECK (role <> 'resident'),
  label        text,                                -- '구룡포읍 자율방재단 2026'
  max_uses     integer,                             -- NULL = 제한 없음
  used_count   integer NOT NULL DEFAULT 0,
  expires_at   timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- 취약 가구 (2026-10-03 확정: 방재단·생활지원사 대리 등록 + 주민 본인 앱 등록 둘 다)
CREATE TABLE IF NOT EXISTS care.households (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label             text NOT NULL,                  -- 방재단 화면 표시명 '삼정리 김OO 어르신 댁' (실명 전체 대신 별칭 권장)
  address           text,
  geom              geometry(Point, 4326) NOT NULL,
  phone             text,
  members           smallint NOT NULL DEFAULT 1 CHECK (members >= 1),
  -- 도움이 필요한 사정 (정해진 값만): elderly 65세 이상 / living_alone 독거 / mobility_limited 보행 불편 /
  --   wheelchair 휠체어 / bedridden 와상 / hearing 청각장애 / vision 시각장애 / cognitive 인지 저하 /
  --   medical_device 산소·투석 등 의료기기 / infant 영유아 / pet 반려동물
  needs             text[] NOT NULL DEFAULT '{}',
  linked_user_id    uuid UNIQUE REFERENCES public.users(id) ON DELETE SET NULL,   -- 본인이 앱으로 등록한 경우
  caregiver_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,          -- 담당 생활지원사
  source            text NOT NULL CHECK (source IN ('self', 'responder', 'caregiver')),
  -- 민감정보 수집 동의 (없으면 등록 불가)
  consent_at        timestamptz NOT NULL,
  consent_method    text NOT NULL CHECK (consent_method IN ('app', 'written', 'verbal')),   -- 앱 동의 / 서면 / 구두(대리 등록자가 확인)
  consent_by        text NOT NULL,                  -- '본인' / '보호자 김OO' 등
  note              text,                           -- 방문 시 참고 (출입 방법 등). 진단명 등 의료정보는 적지 않는다
  active            boolean NOT NULL DEFAULT true,
  created_by        uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_households_geom ON care.households USING gist(geom);
CREATE INDEX IF NOT EXISTS idx_households_caregiver ON care.households(caregiver_user_id);

-- 대피 상황 (incident) — 위험 판정(risk_assessments)이 주의(advisory) 이상이 되면 자동 생성, 방재단이 수동 생성도 가능
CREATE TABLE IF NOT EXISTS care.incidents (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hazard         hazard_type NOT NULL,
  level          risk_level  NOT NULL,
  title          text NOT NULL,                     -- '호우경보 · 구룡포항 일대 침수'
  area           geometry(MultiPolygon, 4326) NOT NULL,
  assessment_id  bigint REFERENCES public.risk_assessments(id) ON DELETE SET NULL,
  source         text NOT NULL CHECK (source IN ('auto', 'manual', 'simulated')),
  started_at     timestamptz NOT NULL DEFAULT now(),
  closed_at      timestamptz,                       -- NULL = 진행 중
  created_by     uuid REFERENCES public.users(id) ON DELETE SET NULL,
  note           text
);
CREATE INDEX IF NOT EXISTS idx_incidents_active ON care.incidents(started_at DESC) WHERE closed_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_incidents_area   ON care.incidents USING gist(area);

-- 대피 대상 = 상황 영역 안의 등록 가구 + (가구 등록은 안 했지만) 대피 확인 경고를 받은 앱 사용자
CREATE TABLE IF NOT EXISTS care.incident_targets (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_id       uuid NOT NULL REFERENCES care.incidents(id) ON DELETE CASCADE,
  household_id      uuid REFERENCES care.households(id) ON DELETE CASCADE,
  user_id           uuid REFERENCES public.users(id) ON DELETE CASCADE,
  alert_id          uuid REFERENCES public.user_alerts(id) ON DELETE SET NULL,
  status            evac_status NOT NULL DEFAULT 'no_response',
  status_via        response_via,
  status_at         timestamptz,
  last_location     geometry(Point, 4326),
  note              text,
  reminder_count    smallint NOT NULL DEFAULT 0,    -- 미응답 재알림 횟수
  last_reminder_at  timestamptz,
  escalated_at      timestamptz,                    -- 미응답·도움 필요 → 방재단에게 넘긴 시각
  assigned_to       uuid REFERENCES public.users(id) ON DELETE SET NULL,   -- 방문 담당 방재단원
  priority_score    real,                           -- B13 결과 (높을수록 먼저). NULL 이면 기본 순서
  priority_reasons  jsonb NOT NULL DEFAULT '[]',    -- [{"factor":"need_help","points":100,"label":"도움 요청"}, …]
  priority_at       timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (household_id IS NOT NULL OR user_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_targets_household ON care.incident_targets(incident_id, household_id) WHERE household_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_targets_user      ON care.incident_targets(incident_id, user_id) WHERE household_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_targets_incident ON care.incident_targets(incident_id, status);

-- 응답 이력 (상태가 바뀔 때마다 1행) — 시연·사후 검토용
CREATE TABLE IF NOT EXISTS care.evacuation_responses (
  id          bigserial PRIMARY KEY,
  target_id   uuid NOT NULL REFERENCES care.incident_targets(id) ON DELETE CASCADE,
  status      evac_status  NOT NULL,
  via         response_via NOT NULL,
  by_user_id  uuid REFERENCES public.users(id) ON DELETE SET NULL,   -- 본인 또는 대신 기록한 방재단원
  location    geometry(Point, 4326),
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_evac_responses_target ON care.evacuation_responses(target_id, created_at);

-- A14 방문 기록
CREATE TABLE IF NOT EXISTS care.visit_logs (
  id            bigserial PRIMARY KEY,
  household_id  uuid NOT NULL REFERENCES care.households(id) ON DELETE CASCADE,
  target_id     uuid REFERENCES care.incident_targets(id) ON DELETE SET NULL,   -- 대피 상황 중 방문이면
  responder_id  uuid REFERENCES public.users(id) ON DELETE SET NULL,
  visited_at    timestamptz NOT NULL DEFAULT now(),
  -- evacuated_with_help 함께 대피 / already_evacuated 이미 대피 / refused 대피 거부 / not_home 부재 /
  -- transported 차량 이송 / other 기타
  result        text NOT NULL CHECK (result IN ('evacuated_with_help', 'already_evacuated', 'refused', 'not_home', 'transported', 'other')),
  status_after  evac_status,                         -- 방문 후 대상 상태 (함께 대피 → evacuated 등)
  location      geometry(Point, 4326),
  note          text
);
CREATE INDEX IF NOT EXISTS idx_visit_logs_household ON care.visit_logs(household_id, visited_at DESC);
