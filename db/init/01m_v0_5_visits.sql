-- =====================================================================
--  구룡가디언 — 스키마 추가분 v0.5 (2026-10-04, A14 방문 기록)
--  다시 실행해도 안전 — 빈 DB 는 docker 초기화가 01m_v0_4 다음에, 기존 DB 는 loader 가 매번 먼저 적용
--
--  방문 기록을 가구 등록 없는 앱 사용자에게도 (2026-10-04 결정): 앱으로 '도움 필요'를 누른 사람이 방재단 1순위인데
--  가구 등록이 없으면 기록을 못 남겼다 → household_id 를 선택값으로 (앱 사용자 방문은 target_id 로 연결).
--  "가구·대상 중 하나는 있어야 함"은 API 가 지킨다 — DB CHECK 로 두면 대피 상황을 지울 때(target_id → NULL) 실패한다
-- =====================================================================

ALTER TABLE care.visit_logs ALTER COLUMN household_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS idx_visit_logs_target ON care.visit_logs(target_id, visited_at DESC);
