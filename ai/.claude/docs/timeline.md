# 개발 타임라인 · 진행 상황

원본(최신, 편집 가능): https://claude.ai/artifact/S1CWwQbkt9mA7TpQbYbbgB
— Artifact 도구 `action: "read"`로 읽는다 (WebFetch 불가). 아래는 2026-09-26 기준 사본(B1·B2·B6·B8 완료 반영)이며, 원본과 다르면 원본이 우선.

3명 · 21일. 마일스톤: Day 7 침수 흐름 앱 동작 / Day 14 전 기능 1차 구현 / Day 21 최종 완성.
핵심 경로: API 명세 → 수집·DB → 침수 기능 연동 → 선제 경고 통합.

## 역할
- A: 서버, DB, 데이터 수집, Risk engine, FastAPI
- **B (이 폴더에서 진행하는 작업): AI(LangGraph·음성) + 경로(GraphHopper·DEM) + 서버 인프라(GCP·배포)**
- C: Flutter 앱·웹, 지도·경로 화면

## B 작업 목록

| ID | Day | 작업 | 선행 | 완료 기준 | 상태 |
| --- | --- | --- | --- | --- | --- |
| B1 | 1–2 | agent 구조 설계 | - | 노드·엣지 확정 | **완료** (2026-09-24) |
| B8 | 1–2 | 개발 환경·GCP·Firebase (docker-compose, PostGIS, .env 규칙, GCP 예산 알림, Firebase 익명인증·FCM) | - | 3명 로컬에서 DB·API 실행 | **완료** (2026-09-24) |
| B2 | 3–4 | LangGraph 골격·관리자 agent (Gemini 연결, 질문 분류→라우팅, 목업 DB tool, /chat 인터페이스) | B1 | 질문 유형별로 올바른 agent 호출 | **완료** (2026-09-24) |
| B3 | 5–6 | 침수 agent·환각 검증 (강수+수위 답변, evidence 대조, 최대 반복) | B2, A3 | 틀린 답 주입 시 검증에서 걸러짐 | 보류 (A1·A3 이후, 사용자 결정 2026-09-26) |
| B4 | 8–10 | 재난 agent 확장·행동 권고 (산사태·강풍태풍·생활안전·위치경로, 규칙 기반 판단 트리, 선제 경고 메시지 함수) | A4, B3, A7 | 재난별 시나리오에 규칙대로 응답 | 미착수 |
| B6 | 8–10 | GraphHopper 구축 (OSM 도로망, 위험지역·맨홀 회피, /route) | A1, A3 | 위험 구역 우회 경로 반환 | **완료** (2026-09-26, 임시 위험지역 데이터) |
| B5 | 11–13 | 의도 검증·다듬기·음성 (STT/TTS, /voice, 지연 측정 → 필요 시 gemini-3.1-live-preview) | B4 | 음성 왕복 동작, 지연 기록 | 미착수 |
| B7 | 11–13 | 경로 가중치·DEM·재계산 (프로필별 가중치, /route/check) | B6, B4 | 프로필별 다른 경로 | **진행 중** (규칙·/route/check·AI 연결 완료, 국토지리정보원 공개DEM 90m 적용, 5m는 이월) |
| B10 | 11–12 | GCP VM·도메인·HTTPS (Caddy, / → 웹, /api → FastAPI) | B8, B6 | 외부에서 /api/health 접속 | 미착수 |
| B9 | 15–16 | 배포 안정화 (재시작 정책, 헬스체크, API 한도, Gemini 속도 제한, Uptime check) | A9 | 강제 종료 후 자동 복구 | 미착수 |

A 작업 중 B와 맞물리는 것: **A7**(Day 3–6, 정적 데이터 적재)에 행동요령 원문 수집 포함 → `action_guides` 테이블, B4의 `get_action_guides`가 사용.

공동: J1 Day 7 침수 연동 · J2 Day 14 1차 통합 · J3 15–16 버그 수정 · J4 17–18 테스트 · J5 19 웹·UI · J6 20 리허설 · J7 21 예비일.

## 다음 세션 시작점 — B7 마무리: 경사 규칙 확인, 완료 처리
완료 기준(B7): **같은 목적지에 프로필별로 다른 경로를 반환한다.** 규칙·재계산·AI 연결 끝, 고도는 국토지리정보원
**공개DEM 90m**(도엽 35903, EPSG:5179, 2025)을 적용했다(2026-09-26). 빈 곳은 SRTM으로 채움.
1. 90m라 짧은 골목 경사를 못 잡는다: 남쪽→서쪽 언덕 경로(35.98,129.56 → 35.995,129.545)에서 세 유형 모두
   max_slope 31%(출발·도착 근처 피할 수 없는 구간으로 추정). 시간·거리는 유형별로 다르다(성인 3.2km 38분, 노약자 3.4km 54분, 휠체어 3.8km 66분).
   → 완료 기준은 충족. 사용자에게 B7 완료 처리 여부를 묻는다(라이브 타임라인 포함).
2. 5m DEM을 구하면(이월 항목) `graphhopper/dem/ngii/`의 90m 파일을 바꾸고 `build_dem.sh` → `docker compose restart graphhopper`,
   `route/guardian_route/profiles.py` 경사 기준(노약자 6·10%, 휠체어 5·8%)을 실제 경로를 보며 조정.
- 이후 후보: B3(A1·A3 확인, Gemini 유료 전환 결정) 또는 B4(재난 agent 확장 — 위치·경로 agent가 `request_route`·`route_profile` 사용).
- 위험 구역은 지금 항상 피한다(Risk engine 활성 판정과 연결은 A3·A4 이후). A7 적재 후 `hazards.py`에 PostGIS 읽기 추가.

## 이월 항목 (끝나면 지운다)
- [ ] **국토지리정보원 DEM 5m 구하기** — 지금은 공개DEM 90m(누구나 받는 것, SRTM과 간격이 같음). 국토정보플랫폼(map.ngii.go.kr)에서
      "공개DEM" 말고 수치표고모형 5m 항목·공급 신청(승인 필요할 수 있음) 확인. 받으면 B7 다음 세션 시작점 2번대로 교체.
      다운로드에 INNORIX-Agent 필요(국토정보플랫폼 공지 notice_id=1408, Mac·Windows·Linux)
- [ ] 공개DEM 북쪽 도엽 추가 — 35903은 북위 36.00°까지라 도로망 북쪽 4km(36.00~36.04)가 빠져 SRTM으로 채워짐.
      구룡포 시가지(약 35.99°)는 덮인다. 5m를 구하면 함께 해결
- [ ] gemini-3.6-flash로 `pytest -m live` 재실행 (무료 한도 회복 또는 유료 전환 후). 지금까지 5/5
- [ ] 시연 전 `.env`를 `GEMINI_MODEL=gemini-3.6-flash`, `GEMINI_TIMEOUT_MS=10000`으로 되돌리기 (지금 Lite·60초 임시)
- [ ] Gemini API 하루 요청 한도(비용 차단) 설정 — 유료 전환 시 GCP 콘솔 Quotas에서
- [ ] A와 DB 조회 방식 합의 (읽기 전용 직접 조회 vs FastAPI 경유, `agent-design.md` 7절 3번) — 미배정
- [ ] C와 `/api/chat` 응답 형식 합의 — 목업의 카드형(판정·수치 칩·할 일·출처·버튼)은 B5에서 확장 (`agent-design.md` 8절)
- [ ] 조위(만조) 데이터: 기획서·목업은 쓰지만 수집 목록에 없음 → A에게 제안 (tools에는 `tide` 종류만 있음)
- [ ] 조하린 GCP·GitHub 권한, 팀원 로컬 실행 확인 — 사용자가 직접 진행
- [ ] 대화 기억은 메모리 저장(ai 재시작 시 소실) — 필요해지면 PostgreSQL checkpointer로

## 일정 리스크 (B1 세션 분석)
- B 과부하: Day 8–10에 B4+B6 동시, Day 11–13에 B5+B7+B10 동시. C는 같은 기간 한 개씩 → B10/B6 일부 이관 검토.
- Day 13 병목: A9 1차 배포가 A5·B7 종료일(13)과 같은 날 → 하루 밀리면 J2 지연.
- B3는 A3와 같은 기간 → A1 목업 JSON(`tools.py` 목업)으로 먼저 진행.

## 작업 기록
- 2026-09-23 B1: 설계 문서·상태 스키마·tool 명세·그래프 골격·토폴로지 테스트 7건 작성. 기획서 대비 변경점(검증 병렬화, 재시도 한도, alert 모드)은 `docs/agent-design.md` 1절.
- 2026-09-24 B1 완료 처리: 범위에서 "행동요령 원문 수집"과 "A와 DB 조회 방식 합의"를 제외(사용자 결정). 두 항목은 미배정 상태로 보류 — 조회 방식은 `docs/agent-design.md` 7절 3번, 원문 저장 형식은 `ActionGuide`(state.py). 원본 타임라인도 같이 갱신.
- 2026-09-24 행동요령 원문 수집을 A7(A 정적 데이터 적재)로 이관, B4 선행에 A7 추가. 원본 타임라인 반영.
- 2026-09-24 코드 점검: 결함 4건을 `docs/code_check_list.md`에 기록 (B2에서 1·2·4번, B5에서 3번 수정).
- 2026-09-24 B8: 저장소 루트 `코드/`(GitHub `kimking73/guryongpo-safety-agent`), docker-compose(db=PostGIS 5433, api=/api/health), `.env` 규칙·README(Mac/Windows), GCP `guryong-guardian-0924`(결제 연결, 0원 예산 알림, API 활성화), Firebase(익명 인증·FCM, firebase-admin 키). 기획서 docx를 git 기록에서 제거(force push). 남은 것: 팀원 구글 계정·GitHub 초대, 팀원 1명 실행 확인. API 사용량 한도는 B2에서 Gemini 키 만들 때 설정.
- 2026-09-24 B8 완료 처리(사용자 결정). 김다인: GitHub 협업자·GCP 편집자 완료. 조하린 초대와 팀원 로컬 실행 확인은 사용자가 직접 진행. 원본 타임라인 반영.
- 2026-09-24 B2: manager Gemini 분류(실패 시 키워드 대체), alert 규칙 라우팅, 턴 간 초기화, checkpointer 타입 등록, ChatService·/api/chat(ai 컨테이너 8001), 테스트 26건 + live 13건. 무료 등급 한도(분당 5·하루 20, 모델별) 때문에 로컬은 임시로 gemini-3.5-flash-lite + 응답 제한 60초. .env 값 뒤 주석이 값으로 읽히던 문제 수정.
- 2026-09-24 B2 완료 처리(사용자 결정). 3.6 Flash 전체 라우팅 확인은 무료 한도 회복·유료 전환 후 재실행 필요. 질문별 라우팅 로그 추가(`docker compose logs -f ai | grep 라우팅`). 원본 타임라인 반영.
- 2026-09-24 세션 마무리: 루트 `CLAUDE.md`·`.claude/docs/architectural_patterns.md`(서비스 공통 패턴) 신설, `ai/CLAUDE.md` 세션 절차·현재 상태 재정리, 이 파일에 다음 세션 시작점(B3)·이월 항목 추가.
- 2026-09-26 B3을 A1·A3 이후로 미루고 B6 먼저 진행(사용자 결정). B6 1단계: `graphhopper/`(GraphHopper 11 jar + Temurin 21, foot·flexible, `fetch_osm.sh`로 Geofabrik 한국 OSM → 구룡포 bbox 129.48,35.92~129.60,36.04 잘라 302KB, 교차점 3,226개), `route/`(FastAPI `POST /api/route`, `/api/route/health`, 장애 시 503·범위 밖 404), compose에 graphhopper·route 추가, 테스트 10건 + live 1건. 구룡포항→실내체육관 부근 986m·710초 확인.
- 2026-09-26 지도 화면(/maps/)에서 경로가 안 뜨던 문제: 화면이 항상 elevation=true로 요청 → 'Elevation not supported!'. config.yml에 SRTM 고도(graph.elevation.provider: srtm, /data/srtm) 추가로 해결. 설정은 이미지에 복사되므로 바꾸면 graph-cache 삭제 + 재빌드.
- 2026-09-26 B6 2단계: 위험 구역·맨홀 회피. `hazards.py`(HazardSource 주입, GeoJSON, 맨홀 점 → 반경 5m 다각형), `polyline.py`, GraphHopper custom_model areas + priority ×0.01(출발지가 구역 안이어도 탈출 가능), 기본 경로와 비교해 `avoided`·`still_inside`, `GET /api/route/hazards`, 요청 `avoid_manholes`. 테스트 19건 + live 2건. 실측: 구룡포항→실내체육관 부근 987m → 1,324m로 flood-001·맨홀 2개 우회, 구역 안 출발 시 still_inside=[flood-001]. `agent-design.md` 5절과 tools.py 목업에 still_inside 추가.
- 2026-09-26 B6 완료 처리(사용자 결정). 지도 화면(/maps/)에 회피 조건을 붙여 넣어 우회를 사용자가 직접 확인. 라이브 타임라인 반영(B6 체크).
- 2026-09-26 B7(진행): `profiles.py`(노약자: 계단 ×0.3, 경사 ≥6% ×0.5·≥10% ×0.2, 속도 ×0.75 / 휠체어: 계단 ×0, 산길 ×0.1, 경사 ≥5% ×0.3·≥8% ×0.05, 속도 ×0.7), 응답에 ascend_m·descend_m·max_slope_pct, `POST /api/route/check`(30m 이탈·남은 경로 위험 구역 → 재계산, 피할 수 없는 구역은 경고만, 20m 안 도착). 휠체어가 급경사를 피하려 산사태 구역을 지나는 문제 → 위험 구역 배수 0.01→0.001. AI `tools.request_route`를 route 서비스 실제 호출로 교체(실패 시 available=False), `route_profile(user)`, compose ai에 ROUTE_URL. 국토지리정보원 DEM: 사용자 선택, `graphhopper/build_dem.sh`(GDAL 컨테이너, 5m → HGT 1초, 빈 곳 SRTM), `entrypoint.sh`(DEM 자동 선택·고도 바뀌면 그래프 재생성). 가짜 DEM으로 변환·전환 검증. 테스트 route 32+live 4, ai 30.
- 2026-09-26 국토지리정보원 공개DEM 90m(35903.img, 도엽 1장) 적용. `build_dem.sh` → 도로망 육지 47% 덮음(북쪽 36.00° 이상·서쪽 끝 빠짐, SRTM으로 채움), 그래프 재생성 확인, live 4건 통과. 5m 구하기·북쪽 도엽은 이월 항목(사용자 결정).
- 2026-09-26 유형별 규칙 검증(공개DEM 90m): 계단 경로 3 + 시가지 무작위 30. 휠체어 계단 33/33 0m, 노약자 계단 ≤ 성인 33/33(구룡포공원 계단 회피, 대안이 263m인 짧은 계단은 이용 — 금지가 아닌 벌점이라 의도대로), 속도 5.00/3.75/3.50km/h, ≥8% 급경사 합계 성인 14.1km → 노약자 9.4km → 휠체어 6.3km. 예외: 휠체어가 급경사를 피하려 산길(×0.1)을 성인보다 조금 더 탄 경로 1건(조정 후보), 출발지가 가짜 산사태 구역 안인 경로 1건(피할 수 없음). live 테스트 2건 추가.
