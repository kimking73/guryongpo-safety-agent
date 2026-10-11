-- =====================================================================
--  구룡가디언 — 스키마 추가분 v0.7 (2026-10-12, 방재단 배정 → 주민에게 도착 예상 시간 안내)
--  다시 실행해도 안전 — 빈 DB 는 docker 초기화가 01m_v0_6 다음에, 기존 DB 는 loader 가 매번 먼저 적용
--
--  방재단원이 대상을 맡으면(PATCH /admin/incidents/{id}/targets/{tid} assigned_to=me) 서버가 방재단원 위치 → 대상 위치
--  도착 예상 시간을 계산해 남기고, 주민 앱에 FCM(kind=responder_assigned)으로 알린다. 시각장애인은 앱이 음성으로 읽는다.
-- =====================================================================

ALTER TABLE care.incident_targets ADD COLUMN IF NOT EXISTS assigned_at timestamptz;
ALTER TABLE care.incident_targets ADD COLUMN IF NOT EXISTS assignee_eta_s integer;   -- NULL = 방재단원 위치를 몰라 계산 못 함
