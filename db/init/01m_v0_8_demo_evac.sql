-- =====================================================================
--  구룡가디언 — 스키마 추가분 v0.8 (2026-10-12, 시연 대피 응답을 서버에 저장 · 다른 계정과 주고받기)
--  다시 실행해도 안전 — 빈 DB 는 docker 초기화가 01m_v0_7 다음에, 기존 DB 는 loader 가 매번 먼저 적용
--
--  시연 모드의 대피 경보 팝업·3버튼 알림 응답은 예전엔 그 기기(브라우저)에만 남아, 같은 브라우저 창끼리만 보였다.
--  이제 서버에 계정당 한 줄로 저장하고(이력은 demo_evac_log), 다른 계정의 방재단원 모드 화면이 읽는다.
--  방재단원의 '실제 출발'·업무 단계(dispatch)는 같은 줄에 써서 주민 화면이 받아 간다.
--  실제 대피 상황(care.incidents·incident_targets·evacuation_responses)과는 완전히 분리 — FCM·이관 없음.
--  공유 항목은 별명·응답·장애 유형(시각·청각·지체)·현재 위치(앱이 보낸 때만, 2026-10-12) — 집 주소·전화는 저장하지 않는다
-- =====================================================================

CREATE TABLE IF NOT EXISTS care.demo_evac (
  user_id      uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,   -- 응답한 주민(사용자 모드) 계정
  status       text NOT NULL DEFAULT 'no_response'
               CHECK (status IN ('no_response', 'need_help', 'evacuating', 'evacuated')),
  needs        text[] NOT NULL DEFAULT '{}',                -- vision · hearing · mobility_limited ('내 정보'의 장애 유형)
  started_at   timestamptz NOT NULL DEFAULT now(),          -- 시연 경보 시작
  responded_at timestamptz,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  dispatch     jsonb,                                       -- 방재단 출동 기록 {departed_at, eta, responder, stage}
  dispatch_by  uuid REFERENCES users(id) ON DELETE SET NULL,
  dispatch_at  timestamptz
);
CREATE INDEX IF NOT EXISTS idx_demo_evac_updated ON care.demo_evac(updated_at);
-- 주민 앱의 현재 위치 (2026-10-12 사용자 요청: 방재단 현황에 실제 위치). 앱이 GPS·지도에서 고른 위치(구룡포 안)일 때만 보낸다.
-- 없으면 방재단 화면엔 시연 기본점 둘레의 가상 위치
ALTER TABLE care.demo_evac ADD COLUMN IF NOT EXISTS lat double precision;
ALTER TABLE care.demo_evac ADD COLUMN IF NOT EXISTS lng double precision;
ALTER TABLE care.demo_evac ADD COLUMN IF NOT EXISTS location_at timestamptz;
-- 방재단 화면에 보일 이름 = 로그인 이메일의 아이디(@ 앞) (2026-10-12 사용자 요청). 서버가 Firebase 토큰에서 읽는다 — 앱이 보낸 값 아님
ALTER TABLE care.demo_evac ADD COLUMN IF NOT EXISTS email_id text;

CREATE TABLE IF NOT EXISTS care.demo_evac_log (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,   -- 시연 주민
  kind        text NOT NULL CHECK (kind IN ('start', 'response', 'dispatch')),
  status      text,
  via         text,
  by_user_id  uuid REFERENCES users(id) ON DELETE SET NULL,           -- 쓴 사람 (dispatch 는 방재단원)
  data        jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_demo_evac_log_user ON care.demo_evac_log(user_id, created_at);
