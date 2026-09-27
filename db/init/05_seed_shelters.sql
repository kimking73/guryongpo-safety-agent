-- 구룡포 대피소 (생활안전지도 IF_0126 지진해일 긴급대피장소 · IF_0122 민방위대피시설) — tools/geocode_shelters.py 생성
-- 좌표: 카카오 로컬 API 주소 검색 (WGS84). 재실행 시 덮어씀
INSERT INTO shelters (source_code, external_id, name, shelter_types, address, is_indoor, is_open, geom) VALUES
  ('safemap', 'OBJ064711100000049', '하정리 269번지 도로', '{tsunami}', '경북 포항시 남구 구룡포읍 동해안로 4540', false, true, ST_SetSRID(ST_MakePoint(129.54677917, 35.96544619), 4326)),
  ('safemap', 'OBJ064711100000050', '하정축양장 앞 공터', '{tsunami}', '경북 포항시 남구 구룡포읍 송정로1번길 22', false, true, ST_SetSRID(ST_MakePoint(129.55242499, 35.97113375), 4326)),
  ('safemap', 'OBJ064711100000018', '대성수산 입구 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 456', false, true, ST_SetSRID(ST_MakePoint(129.57917535, 36.03130789), 4326)),
  ('safemap', 'OBJ064711100000003', '경상북도대수련원 앞 공터', '{tsunami}', '경북 포항시 남구 구룡포읍 하정로 153', false, true, ST_SetSRID(ST_MakePoint(129.55080799, 35.97561168), 4326)),
  ('safemap', 'OBJ064711100000010', '구평리 115-3 도로 옆 공터', '{tsunami}', '경북 포항시 남구 구룡포읍 동해안로 4221', false, true, ST_SetSRID(ST_MakePoint(129.53355107, 35.94409061), 4326)),
  ('safemap', 'OBJ064711100000005', '구, 포항과학기술고등학교 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 병포길52번길 17', false, true, ST_SetSRID(ST_MakePoint(129.550219588924, 35.9829749335714), 4326)),
  ('safemap', 'OBJ064711100000044', '장길리교회 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 동해안로4391번길 8-4', false, true, ST_SetSRID(ST_MakePoint(129.54542274, 35.95481932), 4326)),
  ('safemap', 'OBJ064711100000006', '구룡포 초등학교 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 구룡포길65번길 7', false, true, ST_SetSRID(ST_MakePoint(129.552573880368, 35.9912028273587), 4326)),
  ('safemap', 'OBJ064711100000048', '포스코수련원 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 176', false, true, ST_SetSRID(ST_MakePoint(129.57652815, 36.00939523), 4326)),
  ('safemap', 'OBJ064711100000008', '구룡포청소년회관 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 명월길 51', false, true, ST_SetSRID(ST_MakePoint(129.57382639, 36.02921467), 4326)),
  ('safemap', 'OBJ064711100000011', '남구 구룡포읍 석병리 904-2', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 241-2', false, true, ST_SetSRID(ST_MakePoint(129.57650319, 36.01431585), 4326)),
  ('safemap', 'OBJ064711100000001', 'MGM 그랜드모텔 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 25', false, true, ST_SetSRID(ST_MakePoint(129.56847866, 36.00002962), 4326)),
  ('safemap', 'OBJ064711100000054', '해은사 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 호미로 417', false, true, ST_SetSRID(ST_MakePoint(129.56509886, 35.99693964), 4326)),
  ('safemap', 'OBJ064711100000031', '석병교회 옆', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 318', false, true, ST_SetSRID(ST_MakePoint(129.57779159, 36.021184), 4326)),
  ('safemap', 'OBJ064711100000047', '충혼탑 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 구룡포길 145-10', false, true, ST_SetSRID(ST_MakePoint(129.56073009, 35.99144081), 4326)),
  ('safemap', 'OBJ064711100000007', '구룡포중학교 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 호미로 341', false, true, ST_SetSRID(ST_MakePoint(129.566181571609, 35.9917835586982), 4326)),
  ('safemap', 'OBJ064711100000030', '삼정2리 버스승강장 앞', '{tsunami}', '경북 포항시 남구 구룡포읍 일출로 125', false, true, ST_SetSRID(ST_MakePoint(129.574188837425, 36.0054950079633), 4326)),
  ('safemap', '5030000-S200400141', '해뜨는마을 지하주차장 지하주차장 1층', '{civil_defense}', '경북 포항시 남구 구룡포읍 병포길 124-6', true, true, ST_SetSRID(ST_MakePoint(129.549814017775, 35.9818189808229), 4326)),
  ('safemap', '5030000-S201000002', '여의주타워 지하주차장 1층', '{civil_defense}', '경북 포항시 남구 구룡포읍 호미로 225', true, true, ST_SetSRID(ST_MakePoint(129.555033357144, 35.9903812921264), 4326))
ON CONFLICT (source_code, external_id) DO UPDATE SET name = EXCLUDED.name, shelter_types = EXCLUDED.shelter_types, address = EXCLUDED.address, is_indoor = EXCLUDED.is_indoor, is_open = EXCLUDED.is_open, geom = EXCLUDED.geom, updated_at = now();
