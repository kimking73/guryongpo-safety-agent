-- =====================================================================
--  구룡가디언 — 스키마 추가분 v0.6 (2026-10-08, AI 대화 → 프로필 수집 기록)
--  다시 실행해도 안전 — 빈 DB 는 docker 초기화가 01m_v0_5 다음에, 기존 DB 는 loader 가 매번 먼저 적용
--
--  AI가 대화에서 들은 사용자 정보로 프로필(user_profiles·user_places)을 고칠 때마다 한 줄씩 남긴다 —
--  앱 프로필 화면 'AI가 대화에서 수집한 정보'가 읽는다. 사용자가 한 말(quote)에 건강 정보가 섞일 수 있어 care 스키마
--  (AI 읽기 전용 계정은 public 만 SELECT). 쓰기는 사용자 본인 토큰으로 API(POST /user/profile-updates)를 거친다
-- =====================================================================

CREATE TABLE IF NOT EXISTS care.profile_updates (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  field       text NOT NULL,                          -- age, walking_impaired, …, home_address, frequent_place
  label       text NOT NULL,                          -- 화면 이름 ('나이', '집 주소')
  value       text NOT NULL,                          -- 사람이 읽는 값 ('72세', '구룡포시장 바로 뒤')
  quote       text,                                   -- 근거가 된 사용자 발언
  source      text NOT NULL DEFAULT 'ai_chat',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_profile_updates_user ON care.profile_updates(user_id, created_at DESC);
