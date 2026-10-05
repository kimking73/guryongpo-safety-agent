-- B11 해상 → 최근접 항: 구룡포 일대 항·포구 (route/scripts/build_ports.py 가 route/data/ports.geojson 과 함께 생성)
-- 재적용 안전 (source_code + external_id 로 갱신). 경로 서버는 같은 내용을 ports.geojson 에서 읽는다
INSERT INTO data_sources (code, name, provider, note) VALUES
  ('ports_b11', '구룡포 항·포구 (B11)', '카카오 로컬 / OpenStreetMap', '항·포구 위치 — 카카오 장소 분류 항구·포구·방파제, OSM 방파제로 교차 확인 (route/scripts/build_ports.py)')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ports (external_id, name, kind, berth, land_point, meta, source_code)
SELECT v.*, 'ports_b11' FROM (VALUES
  ('mopo', '모포항', 'other', ST_SetSRID(ST_MakePoint(129.525818, 35.932964), 4326), ST_SetSRID(ST_MakePoint(129.526007, 35.93296), 4326), '{"source": "카카오 ''모포항''(항구,포구)"}'::jsonb),
  ('gupyeong', '구평포구', 'other', ST_SetSRID(ST_MakePoint(129.535875, 35.944431), 4326), ST_SetSRID(ST_MakePoint(129.535867, 35.944773), 4326), '{"source": "카카오 ''구평포구''(항구,포구)"}'::jsonb),
  ('janggil', '장길리 포구', 'other', ST_SetSRID(ST_MakePoint(129.546997, 35.952917), 4326), ST_SetSRID(ST_MakePoint(129.546118, 35.951761), 4326), '{"source": "카카오 ''장길방파제''"}'::jsonb),
  ('hajeong', '하정1리 포구', 'other', ST_SetSRID(ST_MakePoint(129.548071, 35.965088), 4326), ST_SetSRID(ST_MakePoint(129.547881, 35.965004), 4326), '{"source": "카카오 ''하정1리 방파제''"}'::jsonb),
  ('byeongpo', '병포리 포구', 'other', ST_SetSRID(ST_MakePoint(129.553854, 35.981393), 4326), ST_SetSRID(ST_MakePoint(129.554335, 35.979964), 4326), '{"source": "카카오 ''병포리방파제''"}'::jsonb),
  ('guryongpo', '구룡포항', 'national_fishing', ST_SetSRID(ST_MakePoint(129.555466, 35.988961), 4326), ST_SetSRID(ST_MakePoint(129.555752, 35.989311), 4326), '{"source": "카카오 ''구룡포항''(항구,포구), OSM harbour, 국가어항"}'::jsonb),
  ('samjeong', '삼정항', 'other', ST_SetSRID(ST_MakePoint(129.574196, 36.003911), 4326), ST_SetSRID(ST_MakePoint(129.574415, 36.003977), 4326), '{"source": "카카오 ''삼정항''(항구,포구)"}'::jsonb),
  ('seokbyeong1', '석병1리 포구', 'other', ST_SetSRID(ST_MakePoint(129.579119, 36.012589), 4326), ST_SetSRID(ST_MakePoint(129.579123, 36.01273), 4326), '{"source": "카카오 ''석병1리 방파제''"}'::jsonb),
  ('seokbyeong_n', '석병리 북쪽 포구', 'other', ST_SetSRID(ST_MakePoint(129.576319, 36.025019), 4326), ST_SetSRID(ST_MakePoint(129.578226, 36.025479), 4326), '{"source": "OSM 방파제(이름 없음), 행정리 석병리"}'::jsonb),
  ('gangsa', '강사리 포구', 'other', ST_SetSRID(ST_MakePoint(129.578739, 36.040059), 4326), ST_SetSRID(ST_MakePoint(129.578996, 36.039933), 4326), '{"source": "카카오 선착장, 행정리 호미곶면 강사리"}'::jsonb),
  ('masan', '마산리 포구', 'other', ST_SetSRID(ST_MakePoint(129.488743, 36.016917), 4326), ST_SetSRID(ST_MakePoint(129.489067, 36.016675), 4326), '{"source": "카카오 ''마산항방파제'', 영일만 쪽"}'::jsonb),
  ('heunghwan', '흥환리 포구', 'other', ST_SetSRID(ST_MakePoint(129.503676, 36.025014), 4326), ST_SetSRID(ST_MakePoint(129.502337, 36.026058), 4326), '{"source": "OSM 방파제(이름 없음), 행정리 동해면 흥환리"}'::jsonb)
) AS v(external_id, name, kind, berth, land_point, meta)
ON CONFLICT (source_code, external_id) DO UPDATE
  SET name = EXCLUDED.name, kind = EXCLUDED.kind, berth = EXCLUDED.berth,
      land_point = EXCLUDED.land_point, meta = EXCLUDED.meta;
