-- =====================================================================
-- 09 산림청 산사태위험지도 데이터 삭제 (2026-10-10, 사용자 결정)
--   산사태 판정은 기상청 호우특보 × 지정 산사태 취약지역(03_seed) 100m 만 사용한다.
--   예전 09_seed_landslide_riskmap.sql 이 넣은 위험지도 등급 폴리곤·100m 범위(external_id riskmap_*)를
--   기존 DB 에서도 지우고, 그 범위로 만들어진 발효 중 판정은 닫는다. 재적용 안전 (loader 가 매번 실행)
-- =====================================================================
UPDATE risk_assessments SET valid_to = now()
WHERE valid_to IS NULL AND hazard = 'landslide' AND basis->>'kind' = 'riskmap';

DELETE FROM hazard_zones WHERE hazard = 'landslide' AND external_id LIKE 'riskmap\_%';
