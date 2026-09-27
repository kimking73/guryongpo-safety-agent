-- 포항 응급의료기관 (국립중앙의료원) — tools/nmc_medical.py 생성. 구룡포 내 응급의료기관 없음
INSERT INTO medical_facilities (source_code, external_id, name, kind, address, phone, geom, meta) VALUES
  ('nmc', 'A2700005', '경상북도포항의료원', 'emergency_room', '경상북도 포항시 북구 용흥로 36 (용흥동, (용흥동))', '054-247-0551', ST_SetSRID(ST_MakePoint(129.3549930430143, 36.03462413480262), 4326), '{"er_phone": "054-245-0129", "emergency_class": "지역응급의료기관"}'::jsonb),
  ('nmc', 'A2700008', '에스포항병원', 'emergency_room', '경상북도 포항시 남구 희망대로 352 (이동, 에스포항병원)', '054-289-9000', ST_SetSRID(ST_MakePoint(129.3314002552, 36.0348228983), 4326), '{"er_phone": "054-289-9120", "emergency_class": "지역응급의료기관"}'::jsonb),
  ('nmc', 'A2702563', '의료법인은성의료재단좋은선린병원', 'emergency_room', '경상북도 포항시 북구 대신로 43 (대신동)', '054-245-5000', ST_SetSRID(ST_MakePoint(129.36704339734024, 36.048089061494764), 4326), '{"er_phone": "054-245-5200", "emergency_class": "지역응급의료기관"}'::jsonb),
  ('nmc', 'A2700016', '포항성모병원', 'emergency_room', '경상북도 포항시 남구 대잠동길 17 (대잠동)', '054-272-0151', ST_SetSRID(ST_MakePoint(129.33981334567275, 36.01585627687779), 4326), '{"er_phone": "054-260-8600", "emergency_class": "권역응급의료센터"}'::jsonb),
  ('nmc', 'A2700002', '포항세명기독병원', 'emergency_room', '경상북도 포항시 남구 포스코대로 351 (대도동)', '054-275-0005', ST_SetSRID(ST_MakePoint(129.3615706051, 36.0181008246), 4326), '{"er_phone": "054-289-1711", "emergency_class": "지역응급의료센터"}'::jsonb)
ON CONFLICT (source_code, external_id) DO UPDATE SET name = EXCLUDED.name, address = EXCLUDED.address, phone = EXCLUDED.phone, geom = EXCLUDED.geom, meta = EXCLUDED.meta;
