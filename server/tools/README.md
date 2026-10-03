# server/tools — 개발용 스크립트 (1주차 A1·A7)

서버 컨테이너에는 들어가지 않는다. `cd server/tools && python3 <스크립트>` 로 실행.
키는 `server/dt_config.txt` 에서 읽는다 (gitignore — 팀 비공개 채널로 받은 값을 `KEY=값` 줄로).

| 스크립트 | 하는 일 | 출력 |
|---|---|---|
| `fetch_dt.py [이름]` | 포항 DT·기상청·생활안전지도 API 일괄 호출 (`dt_apis.json`) | `server/mock/external/*` 원문 |
| `landslide_zones.py` | 산사태 취약지역 CSV(`server/data/`) → SQL·GeoJSON | `db/init/03_seed_landslide.sql` |
| `seed_knowledge.py` | 포항시 재난안전 페이지 → 행동요령·지원제도·긴급전화 | `db/init/04_seed_knowledge.sql` |
| `geocode_shelters.py` | 대피소 주소 → 좌표 (카카오 로컬, `KAKAO_REST_KEY`) | `db/init/05_seed_shelters.sql` |
| `nmc_medical.py` | 응급의료기관 (국립중앙의료원, `DATA_GO_KR_KEY`) | `db/init/06_seed_medical.sql` |
| `validate.py` | 명세(`server/spec/openapi.yaml`) ↔ 목업 검증 (대응표 `tests/spec_mocks.py`, pytest 판은 `tests/test_spec.py`) | – |
| `make_mocks.py` | v0.2 목업 재생성 — **v0.3 목업(role·household·alert-response·admin.*)은 직접 편집**, 다시 돌리면 v0.3 필드가 지워지니 주의 | `server/mock/*` |
| `pohang_dt_*.py` · `kma_*.py` | 원천 응답 변환기 원본 (수집기 사본은 `server/collector/converters/`) | – |

`db/init/*.sql` 시드를 다시 만들면 `docker compose run --rm loader` 로 기존 DB 에 적용한다 (볼륨 초기화 불필요, 스키마 01 변경만 `down -v`).
생성하는 SQL 은 여러 번 적용해도 같은 결과여야 한다 (ON CONFLICT upsert 또는 TRUNCATE 후 삽입) — `server/tests/test_loader.py` 가 검사.
