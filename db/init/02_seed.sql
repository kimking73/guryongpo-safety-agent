-- =====================================================================
--  구룡가디언 — 기초 데이터 (데이터 출처 + 위험 판단 기준)
--  schema.sql 실행 후 적용. 여러 번 적용해도 같은 결과 (loader: docker compose run --rm loader)
-- =====================================================================

INSERT INTO data_sources (code, name, provider, base_url, note) VALUES
  ('pohang_dt', '포항 디지털 트윈 플랫폼', '포항시',           NULL, '수위계 10 · 대기환경 측정기 24 · 자외선지수 실시간 (https://genix.pohang-eum.kr/dpg, serviceKey)'),
  ('kma',       '기상청 API허브 / 공공데이터포털', '기상청',     'https://apihub.kma.go.kr', '동네예보(초단기실황·초단기예보·단기예보, 격자 105,94 / 106,94), 중기예보, 기상특보, 지상관측(ASOS/AWS) — authKey'),
  ('safety24',  '재난안전24 (국민재난안전포털)', '행정안전부', NULL, '재난문자, 태풍 정보'),
  ('safemap',   '생활안전지도',                 '행정안전부', 'https://www.safemap.go.kr', '대피소, 의료시설'),
  ('datagokr',  '공공데이터포털',               '각 기관',   'https://www.data.go.kr', '산사태 위험지역 등'),
  ('pohang_safety', '포항시 재난안전',          '포항시',     NULL, '행동요령, 보험/복구 지원'),
  ('osm',       'OpenStreetMap',               'OSM',       'https://www.openstreetmap.org', '도로망 (GraphHopper)'),
  ('ngii_dem',  '국토지리정보원 DEM',            '국토지리정보원', NULL, '경사도 (오르막 회피)'),
  ('nmc',       '국립중앙의료원 응급의료정보',   '국립중앙의료원', 'https://apis.data.go.kr/B552657/ErmctInfoInqireService', '응급의료기관 위치·응급실 전화, 실시간 가용병상'),
  ('manual',    '팀 직접 입력',                  '구룡포는구룡', NULL, '행동요령 정리본, 테스트 데이터')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, provider = EXCLUDED.provider, base_url = EXCLUDED.base_url, note = EXCLUDED.note;

-- 자체 위험 판정 엔진 (server/risk) — ingest_runs 에 판정 실행 기록
INSERT INTO data_sources (code, name, provider, note) VALUES
  ('risk', '위험 판정 엔진', '구룡포는구룡', '관측값 + risk_rules → risk_assessments'),
  ('loader', '정적 데이터 적재 (loader)', '구룡포는구룡', 'db/init 02~ 시드를 다시 적용 (python -m loader) — ingest_runs 에 적재 기록')
ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, provider = EXCLUDED.provider, note = EXCLUDED.note;

-- ---------------------------------------------------------------------
-- 위험 판단 기준
--  risk_level 매핑: advisory = 주의보 / warning = 경보
--  자외선: normal=낮음, watch=보통, advisory=높음, warning=매우높음, critical=위험
-- ---------------------------------------------------------------------
-- id 를 고정한다: risk_assessments.rule_id 가 참조하고, 판정 엔진·문서가 번호(9, 21~28 등)로 부른다.
-- 재적용(loader) 시 같은 id 의 기준값을 갱신한다. 새 기준은 끝 번호 다음(31~)으로 추가.
INSERT INTO risk_rules (id, hazard, level, label, metric, operator, threshold, threshold_max, duration_min, condition, source_name) VALUES
-- 호우 (예상 누적강우량; 관측 누적값에도 동일 적용)
  (1, 'heavy_rain', 'advisory', '호우주의보', NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"metric":"rain_3h","op":">=","value":60},{"metric":"rain_12h","op":">=","value":110}]}', '기상청 기상특보 발표기준'),
  (2, 'heavy_rain', 'warning',  '호우경보',   NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"metric":"rain_3h","op":">=","value":90},{"metric":"rain_12h","op":">=","value":180}]}', '기상청 기상특보 발표기준'),
-- 강풍 (육상 / 산지 구분: stations.is_mountain) — 기상청 관측(kma)만 사용. 포항 DT 대기측정기 풍속(winsp)은 지상 저고도 참고값이라 판단 제외
  (3, 'strong_wind', 'advisory', '강풍주의보', NULL, 'composite', NULL, NULL, NULL,
   '{"land":{"any":[{"metric":"wind_speed","op":">=","value":14},{"metric":"wind_gust","op":">=","value":20}]},
     "mountain":{"any":[{"metric":"wind_speed","op":">=","value":17},{"metric":"wind_gust","op":">=","value":25}]}}', '기상청 기상특보 발표기준'),
  (4, 'strong_wind', 'warning',  '강풍경보',   NULL, 'composite', NULL, NULL, NULL,
   '{"land":{"any":[{"metric":"wind_speed","op":">=","value":21},{"metric":"wind_gust","op":">=","value":26}]},
     "mountain":{"any":[{"metric":"wind_speed","op":">=","value":24},{"metric":"wind_gust","op":">=","value":30}]}}', '기상청 기상특보 발표기준'),
-- 풍랑 (해상, 어업 종사자 대상)
  (5, 'high_seas', 'advisory', '풍랑주의보', NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"metric":"wind_speed","op":">=","value":14,"duration_min":180},{"metric":"wave_height","op":">=","value":3}]}', '기상청 기상특보 발표기준'),
  (6, 'high_seas', 'warning',  '풍랑경보',   NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"metric":"wind_speed","op":">=","value":21,"duration_min":180},{"metric":"wave_height","op":">=","value":5}]}', '기상청 기상특보 발표기준'),
-- 태풍: 특보 연동 + 강풍반경 진입
  (7, 'typhoon', 'advisory', '태풍주의보/영향권', NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"weather_warning":"typhoon","level":"advisory"},{"within":"typhoon_tracks.radius_15ms_km"}]}', '기상청 기상특보 / 재난안전24'),
  (8, 'typhoon', 'warning',  '태풍경보',          NULL, 'composite', NULL, NULL, NULL,
   '{"any":[{"weather_warning":"typhoon","level":"warning"},{"within":"typhoon_tracks.radius_25ms_km"}]}', '기상청 기상특보 / 재난안전24'),
-- 침수: 지표면 수위계(ROAD) 침수심 150mm(15cm) 이상이면 침수로 판단 (포항 DT 등급 기준은 파일 끝 21~28번)
  (9, 'flood', 'advisory', '침수 발생', 'flood_depth', '>=', 150, NULL, NULL,
   '{"station_kind":"road_flood","unit":"mm","buffer_m":150,"note":"영향 범위 = 수위계 반경 150m"}', '정부 침수 판단 기준(15cm) / 포항 디지털 트윈 지표면 수위계'),
-- 산사태: 호우 특보 중 + 사용자/지점이 산사태 위험지역 내부 또는 인접(100m)
-- 100m 버퍼 근거: 김경수 외(2006), "자연사면에서 발생된 토석류산사태의 기하양상", KIGAM
-- (https://data.kigam.re.kr/ieg/cmmn/downloadFile.do?fileName=Y3061006.PDF). 1998년 집중호우 산사태
-- 1,582건을 지질별 3개 지역(편마암류=장흥·화강암류=상주·제3기퇴적암류=포항)으로 분석했는데, 그 중
-- 구룡포와 같은 지질조건인 "제3기퇴적암류(포항)" 지역 산사태의 진행방향 길이는 평균 36m, 91%가
-- 60m 이내에서 멈췄다(화강암류=상주 지역은 평균 82m, 78%가 100m 미만). 지정 취약지역 자체가
-- 점+면적을 원으로 근사한 폴리곤이라 경계 오차가 있어, 실측된 진행거리보다 넉넉한 100m를 주의보
-- 단계의 안전 마진으로 채택하고, 경보 단계에서는 지정 영역 내부로 좁혀 판단한다.
  (10, 'landslide', 'advisory', '산사태 주의', NULL, 'composite', NULL, NULL, NULL,
   '{"all":[{"risk":"heavy_rain","min_level":"advisory"},{"within":"hazard_zones.landslide","buffer_m":100}]}',
   '공공데이터포털 산사태 위험지역 + 기상특보 / 버퍼 100m 근거: KIGAM 김경수 외(2006) 포항(제3기퇴적암류) 산사태 진행거리 평균 36m·91%가 60m 이내'),
  (11, 'landslide', 'warning',  '산사태 경고', NULL, 'composite', NULL, NULL, NULL,
   '{"all":[{"risk":"heavy_rain","min_level":"warning"},{"within":"hazard_zones.landslide","buffer_m":0}]}', '공공데이터포털 산사태 위험지역 + 기상특보'),
-- 미세먼지 · 초미세먼지 (포항 DT 대기환경 측정기 24대, 원천 측정 시각 60분 이내 값만 사용)
--   advisory/warning = 대기환경보전법 경보 발령기준 (시간평균 농도 2시간 이상 지속 → DUST_SUSTAINED_SQL)
  (12, 'fine_dust',      'advisory', '미세먼지 주의보',   'pm10', '>=',      150, NULL, 120,  '{"max_age_min":60,"buffer_m":300,"agg":"hourly_avg"}', '대기환경보전법 시행규칙 (경보 발령기준)'),
  (13, 'fine_dust',      'warning',  '미세먼지 경보',     'pm10', '>=',      300, NULL, 120,  '{"max_age_min":60,"buffer_m":300,"agg":"hourly_avg"}', '대기환경보전법 시행규칙 (경보 발령기준)'),
  (14, 'ultrafine_dust', 'advisory', '초미세먼지 주의보', 'pm25', '>=',      75,  NULL, 120,  '{"max_age_min":60,"buffer_m":300,"agg":"hourly_avg"}', '대기환경보전법 시행규칙 (경보 발령기준)'),
  (15, 'ultrafine_dust', 'warning',  '초미세먼지 경보',   'pm25', '>=',      150, NULL, 120,  '{"max_age_min":60,"buffer_m":300,"agg":"hourly_avg"}', '대기환경보전법 시행규칙 (경보 발령기준)'),
-- 자외선지수 (포항 DT /sensor/latest/uvIndex: 구룡포 전역 값 1개 → 버퍼 대신 구룡포읍 전체에 적용)
  (16, 'uv', 'normal',   '자외선 낮음',     'uv_index', 'between', 0,  2.99, NULL, '{"max_age_min":90,"area":"guryongpo"}', '기상청 자외선지수 단계'),
  (17, 'uv', 'watch',    '자외선 보통',     'uv_index', 'between', 3,  5.99, NULL, '{"max_age_min":90,"area":"guryongpo"}', '기상청 자외선지수 단계'),
  (18, 'uv', 'advisory', '자외선 높음',     'uv_index', 'between', 6,  7.99, NULL, '{"max_age_min":90,"area":"guryongpo"}', '기상청 자외선지수 단계'),
  (19, 'uv', 'warning',  '자외선 매우높음', 'uv_index', 'between', 8, 10.99, NULL, '{"max_age_min":90,"area":"guryongpo"}', '기상청 자외선지수 단계'),
  (20, 'uv', 'critical', '자외선 위험',     'uv_index', '>=',      11, NULL, NULL, '{"max_age_min":90,"area":"guryongpo"}', '기상청 자외선지수 단계'),
-- 포항 DT 원천 등급(level) 기반: 1 정상 / 2 보통 / 3 주의 / 4 경보 / 5 위험  (21~24 침수, 25~28 강우)
--   수위계류(HOLE·ROAD·RIVER) → 침수, 강우량계(RAIN) → 호우. 스마트맨홀(HOLE)은 value 를 쓰지 않고 level 만 사용
  (21, 'flood', 'watch', '침수 보통 (포항 DT 2단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":["manhole","road_flood","river_level"],"source_level":{"=":2},"buffer_m":100}', '포항 디지털 트윈 수위계 등급'),
  (22, 'flood', 'advisory', '침수 주의 (포항 DT 3단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":["manhole","road_flood","river_level"],"source_level":{"=":3},"buffer_m":150}', '포항 디지털 트윈 수위계 등급'),
  (23, 'flood', 'warning', '침수 경보 (포항 DT 4단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":["manhole","road_flood","river_level"],"source_level":{"=":4},"buffer_m":300}', '포항 디지털 트윈 수위계 등급'),
  (24, 'flood', 'critical', '침수 위험 (포항 DT 5단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":["manhole","road_flood","river_level"],"source_level":{"=":5},"buffer_m":500}', '포항 디지털 트윈 수위계 등급'),
  (25, 'heavy_rain', 'watch', '강우 보통 (포항 DT 2단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":"rain_gauge","source_level":{"=":2}}', '포항 디지털 트윈 강우량계 등급'),
  (26, 'heavy_rain', 'advisory', '강우 주의 (포항 DT 3단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":"rain_gauge","source_level":{"=":3}}', '포항 디지털 트윈 강우량계 등급'),
  (27, 'heavy_rain', 'warning', '강우 경보 (포항 DT 4단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":"rain_gauge","source_level":{"=":4}}', '포항 디지털 트윈 강우량계 등급'),
  (28, 'heavy_rain', 'critical', '강우 위험 (포항 DT 5단계)', NULL, 'composite', NULL, NULL, NULL,
   '{"station_kind":"rain_gauge","source_level":{"=":5}}', '포항 디지털 트윈 강우량계 등급'),
-- 29·30: 미세먼지 '나쁨' (에어코리아 예보등급, 순간값 · 60분 이내 · 민감군 안내용)
  (29, 'fine_dust',      'watch', '미세먼지 나쁨',   'pm10', 'between', 81, 150, NULL, '{"max_age_min":60,"buffer_m":300}', '에어코리아 대기질 예보등급 (PM10 나쁨 81~150)'),
  (30, 'ultrafine_dust', 'watch', '초미세먼지 나쁨', 'pm25', 'between', 36, 75,  NULL, '{"max_age_min":60,"buffer_m":300}', '에어코리아 대기질 예보등급 (PM2.5 나쁨 36~75)')
ON CONFLICT (id) DO UPDATE SET hazard = EXCLUDED.hazard, level = EXCLUDED.level, label = EXCLUDED.label, metric = EXCLUDED.metric,
  operator = EXCLUDED.operator, threshold = EXCLUDED.threshold, threshold_max = EXCLUDED.threshold_max, duration_min = EXCLUDED.duration_min,
  condition = EXCLUDED.condition, source_name = EXCLUDED.source_name;
SELECT setval(pg_get_serial_sequence('risk_rules', 'id'), (SELECT max(id) FROM risk_rules));

-- ---------------------------------------------------------------------
-- 포항 DT 수위계·강우량계 10개 (2026-09 실제 응답 · 수집기가 매번 upsert 하므로 개발용 초기값)
--   HOLE 스마트맨홀 3 / ROAD 지표면 수위계 5 / RIVER 하천 수위계 1 / RAIN 강우량계 1
-- ---------------------------------------------------------------------
INSERT INTO stations (source_code, external_id, name, kind, address, geom, meta) VALUES
  ('pohang_dt', '1', '구룡포교_하천수위계', 'river_level', '경북 포항시 남구 구룡포읍 병포리 157-279',
   ST_SetSRID(ST_MakePoint(129.550467, 35.987244), 4326), '{"eui": "50F8A5FFFE0EF546", "sensor_type": "RIVER"}'),
  ('pohang_dt', '2', '하나과메기_스마트맨홀', 'manhole', '경북 포항시 남구 구룡포읍 호미로 152',
   ST_SetSRID(ST_MakePoint(129.549278, 35.985929), 4326), '{"eui": "0017B2FFFE503373", "sensor_type": "HOLE"}'),
  ('pohang_dt', '3', '로터리종합건재_스마트맨홀', 'manhole', '경북 포항시 남구 구룡포읍 호미로 174-1',
   ST_SetSRID(ST_MakePoint(129.551115, 35.987373), 4326), '{"eui": "0017B2FFFE503374", "sensor_type": "HOLE"}'),
  ('pohang_dt', '4', '구룡포수협_스마트맨홀', 'manhole', '경북 포항시 구룡포읍 구룡포리 954-30',
   ST_SetSRID(ST_MakePoint(129.557327, 35.991235), 4326), '{"eui": "0017B2FFFE503375", "sensor_type": "HOLE"}'),
  ('pohang_dt', '5', '구룡포읍행정복지센터_강우량계', 'rain_gauge', '경북 포항시 남구 구룡포읍 호미로 133',
   ST_SetSRID(ST_MakePoint(129.546115, 35.984987), 4326), '{"eui": "50F8A5FFFE0EF545", "sensor_type": "RAIN"}'),
  ('pohang_dt', '7', '하나과메기_지표면 수위계', 'road_flood', '경북 포항시 남구 병포리 585',
   ST_SetSRID(ST_MakePoint(129.549245, 35.986115), 4326), '{"eui": "50F8A5FFFE0EF548", "sensor_type": "ROAD"}'),
  ('pohang_dt', '8', '구룡포파출소_지표면 수위계', 'road_flood', '경북 포항시 남구 구룡포읍 구룡포리 954-6',
   ST_SetSRID(ST_MakePoint(129.553056, 35.988698), 4326), '{"eui": "50F8A5FFFE0EF549", "sensor_type": "ROAD"}'),
  ('pohang_dt', '9', '해양경찰서_지표면 수위계', 'road_flood', '경북 포항시 남구 구룡포읍 호미로 216-1',
   ST_SetSRID(ST_MakePoint(129.554646, 35.98947), 4326), '{"eui": "50F8A5FFFE0EF54A", "sensor_type": "ROAD"}'),
  ('pohang_dt', '10', '구룡포환승센터_지표면 수위계', 'road_flood', '경북 포항시 남구 구룡포읍 구룡포리 954-31',
   ST_SetSRID(ST_MakePoint(129.556057, 35.99069), 4326), '{"eui": "50F8A5FFFE0EF54B", "sensor_type": "ROAD"}'),
  ('pohang_dt', '11', '구룡포수협_지표면 수위계', 'road_flood', '경북 포항시 남구 구룡포읍 구룡포리 954-30',
   ST_SetSRID(ST_MakePoint(129.557354, 35.991109), 4326), '{"eui": "50F8A5FFFE0EF54C", "sensor_type": "ROAD"}')
ON CONFLICT (source_code, external_id) DO NOTHING;   -- 이미 있으면 수집기 값 유지

-- 맨홀 (경로 회피용): 포항 DT 스마트맨홀 = 구룡포에서 위치를 확인한 유일한 맨홀 데이터 (하수관로 맨홀 공개 데이터 없음)
INSERT INTO manholes (source_code, external_id, kind, geom)
SELECT source_code, external_id, 'smart', geom FROM stations WHERE source_code = 'pohang_dt' AND kind = 'manhole'
ON CONFLICT (source_code, external_id) DO UPDATE SET kind = EXCLUDED.kind, geom = EXCLUDED.geom;

-- ---------------------------------------------------------------------
-- 공공 긴급전화 (전국 공통). 포항시·구룡포 기관 번호는 포항시 재난안전 페이지에서 확인 후 추가
-- ---------------------------------------------------------------------
-- 재적용 시 중복 방지: 긴급전화는 02(전국 공통) → 04(포항시 페이지) 순서로 매번 새로 넣는다 (참조하는 테이블 없음)
TRUNCATE public_hotlines RESTART IDENTITY;
INSERT INTO public_hotlines (name, phone, scope, hazards, targets, priority, note, source_name) VALUES
  ('119 화재·구조·구급', '119', 'national', '{}', '{all}', 1, '위치·건강정보 함께 전달 (emergency_events)', '소방청'),
  ('112 경찰',           '112', 'national', '{}', '{all}', 2, NULL, '경찰청'),
  ('122 해양 긴급신고',  '122', 'national', '{typhoon,high_seas}', '{fisher}', 3, '해상 사고·선박 조난', '해양경찰청'),
  ('131 기상콜센터',     '131', 'national', '{heavy_rain,strong_wind,typhoon,high_seas}', '{all}', 20, '날씨·특보 문의', '기상청');
