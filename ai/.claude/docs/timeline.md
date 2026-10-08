# 개발 타임라인 · 진행 상황

원본(최신, 편집 가능): https://claude.ai/artifact/H3ofVAbENCmCvRtAvaGLAi (2026-10-03 사용자가 바꾼 28일판. 이전 21일판 S1CWwQbkt9mA7TpQbYbbgB는 쓰지 않음)
— Artifact 도구 `action: "read"`로 읽는다 (WebFetch 불가). 아래는 2026-10-03 기준 사본이며, 원본과 다르면 원본이 우선.
Day 1 = 2026-09-23 (Day 10 = 10-02, Day 11 = 10-03).

3명 · 28일. 마일스톤: Day 7 침수 흐름 앱 동작 / Day 14 기존 기능 1차 구현 / **Day 21 추가 기능 7종 통합** / Day 28 최종 완성.
핵심 경로: API 명세 → 수집·DB → 침수 기능 연동 → 선제 경고 통합.
추가 기능 경로: 선제 경고(A5) → 대피 응답(A12) → 가구 등록(A13) → 우선순위(B13) → 방재단 대시보드(A14, C8).

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
| B3 | 5–6 | 침수 agent·환각 검증 (강수+수위 답변, evidence 대조, 최대 반복) | B2, A3 | 틀린 답 주입 시 검증에서 걸러짐 | **완료** (2026-10-01, 틀린 답 10/10 걸러짐·맞는 답 3/3 통과) |
| B4 | 8–10 | 재난 agent 확장·행동 권고 (산사태·강풍태풍·생활안전·위치경로, 규칙 기반 판단 트리, 선제 경고 메시지 함수) | A4, B3, A7 | 재난별 시나리오에 규칙대로 응답 | **진행 중** (2026-10-03: agent 4종·행동 권고·재난 단계 완료. 남은 것: 선제 경고 메시지 함수(A5용, 사용자 결정으로 다음 작업). 2026-10-08 지원·복구 agent 추가. 완료 처리는 사용자 확인) |
| B6 | 8–10 | GraphHopper 구축 (OSM 도로망, 위험지역·맨홀 회피, /route) | A1, A3 | 위험 구역 우회 경로 반환 | **완료** (2026-09-26, 임시 위험지역 데이터 / 회피 시연 16/16, 2026-10-01) |
| B5 | 11–13 | 의도 검증·다듬기·음성 (STT/TTS, /voice, 지연 측정 → 필요 시 OpenAI Realtime) | B4 | 음성 왕복 동작, 지연 기록 | **진행 중** (2026-10-03: 의도 검증·카드형 다듬기·숫자 재검증·지연 측정·/api/voice·/api/tts·앱 마이크/재생 완료. 음성 대화(실제 Google 왕복·음성 지연 기록)는 사용자 결정으로 나중에 — 코드는 준비됨, 키 없으면 503) |
| B7 | 11–13 | 경로 가중치·DEM·재계산 (프로필별 가중치, /route/check) | B6, B4 | 프로필별 다른 경로 | **완료** (원본에서 완료 처리, 2026-10-03 확인. 공개DEM 90m, 노약자 경사 기준선 1/18·1/12) |
| B10 | 11–12 | GCP VM·도메인·HTTPS (Caddy, / → 웹, /api → FastAPI) | B8, B6 | 외부에서 /api/health 접속 | **완료 기준 달성** (2026-10-04: https://34-64-177-195.nip.io/api/health 200, 웹앱 `/` 배포. 2026-10-05 Firebase 웹 설정·로그인·웹 배포까지 끝. 라이브 타임라인 완료 처리는 사용자 확인) |
| B11 | 15–17 | **추가 2** 해상 → 최근접 항 → 육상 경로 (항구·접안 지점 좌표, 해상 판정(해안선, PostGIS), 최근접 항 거리·방위, 항 → 대피소는 /route, 응답에 해상·육상 구간 구분, 위치·경로 agent 연결) | B7 | 해상 좌표 → 최근접 항 + 항 → 대피소 경로 | **1차 구현** (2026-10-05: `POST /api/route/sea`, 항·포구 12곳, OSM 해안선 육지 판정. 사용자: B11 로직은 나중에 다시 수정 — 응답 형식만 고정. 2026-10-05 방파제·육지 통과 수정(무작위 400곳 0구간), VM 배포. 남은 것: 판정 세부 확정, AI 위치·경로 agent 연결) |
| B12 | 17–18 | **추가 7** 음성 대피 확인 (경고 시 TTS 질문, STT 결과 → A12 상태 3종 분류(핵심 문구 규칙 우선), 불명확하면 재질문, POST /alerts/{id}/response(응답 수단: 음성), 소음 인식률 측정) | B5, A12 | 음성 질문 → "대피 완료" 발화 → 상태 기록이 화면 조작 없이 동작 | 미착수 |
| B13 | 19–20 | **추가 4** 방문 우선순위 판단 (가구 위험 판정(A4)·주민 상태(A13)·대피 응답(A12) → 규칙 점수식, 가중치 표, 응답 순서 도움 필요 > 미응답 > 이동 중 > 대피 완료, 바뀌면 재계산, 순위 근거 항목별 표시) | A4, A12, A13 | 같은 입력에 같은 순서 + 근거 반환 | **구현** (2026-10-08, 사용자 규칙: 위험지역 안만 · 도움요청+장애 > 도움요청 > 응답없음+장애 > 응답없음 > 대피 중 > 완료, 장애=시각·청각·지체, 같은 순위는 방재단원 위치에서 가까운 순(없으면 오래 기다린 순). `server/app/priority.py`, 읽을 때마다 계산·DB 저장 안 함. VM 배포·완료 처리는 사용자 확인) |
| B9 | 22–23 | 배포 안정화 (재시작 정책, 헬스체크, API 한도, OpenAI 사용 한도, Uptime check) | A9 | 강제 종료 후 자동 복구 | 미착수 (원본에서 15–16 → 22–23으로 이동) |

| C8 | 19–20 | (C 레인, 사용자 요청으로 B가 진행) 가구 등록·민감정보 동의(별도 화면)·방재단 대시보드(우선순위 명단·지도)·방문 결과 입력·방재단 역할만 진입·해상/육상 구간 표시 | A13, A14, B11, C6 | 방재단 계정에서 명단 확인과 방문 기록 입력이 화면에서 동작 | **구현·VM 배포** (2026-10-05, `app/lib/patrol_screens.dart`. VM 배포·초대 코드 발급까지 끝, 시연 가구 14곳 서버 DB. 완료 처리는 사용자 확인) |

A 작업 중 B와 맞물리는 것: **A7**(Day 3–6, 정적 데이터 적재)에 행동요령 원문 수집 포함 → `action_guides` 테이블, B4의 `get_action_guides`가 사용.

공동: J1 Day 7 침수 연동 · J2 Day 14 1차 통합 · **J8 Day 21 추가 기능 통합** · J3 22–23 버그 수정 · J4 24–25 테스트 · J5 26 웹·UI · J6 27 리허설 · J7 28 예비일.
B와 맞물리는 새 A·C 작업: A12(15–16 대피 응답 API, B12·B13 선행) · A13(17–18 취약 가구·민감정보 동의·방재단 권한, B13 선행) · A14(19–20 방문 기록, B13 필요) · C8(19–20 해상 경로 화면, B11 필요) · C7(17–18 접근성, B12 필요).
원본 "확정 필요": 대피 확인 버튼 3종 문구, 상태 대시보드 범위, 방재단 계정 부여 방식, 취약 가구 등록 주체, 제출 기한이 28일과 맞는지.

## 다음 세션 시작점 (2026-10-08 갱신, Day 16 — 28일판 기준)
**현재 상태**: B1·B2·B3·B6·B7·B8 완료 / **B10** 완료 기준 달성(https://34-64-177-195.nip.io) / **B11** 1차 + AI 연결(10-07) /
**C8**(B가 진행) 배포 / **B4** 선제 경고 메시지 함수만 남음 + 지원·복구 agent 추가(10-08) / **B5** 음성만 남음(나중에).
B4·B5·B10·J1·B11 완료 처리(라이브 타임라인 포함)는 사용자에게 먼저 묻는다 — 아직 답 없음.
마지막 앱 커밋 e47f177 (웹 `push_web.sh` 반영, 2026-10-08 23:25). 이 맥에서 VM ssh 됨(10-08 확인). VM 사용자 계정은 10-07에 모두 지웠고 새로 로그인한 계정만 있다.
테스트 기준: server 220 passed·8 skipped, route 68 passed(live 제외), ai 208(live·db 제외),
app 101개 중 기존 실패 7개(disaster_center "map options remain stable"·location 3·remote_mapping 1·route_and_places 2 — 1개는 10분 멈춤).

**2026-10-07~08 한 일 (자세한 건 작업 기록)**:
- 경로: 가까운(회피 없음)·안전·오르막 회피 3종, 자동차 경로(GraphHopper car), 시연 산사태 범위 1등급.
- 로그인 강제(익명 없음), VM 계정 전부 삭제(서버 기록만, 백업 `~/backups/db-before-user-wipe-20261007-1750.dump`).
- **사용자 정보 = 서버 프로필 하나** (아래 구조), 'AI가 대화에서 수집한 정보' 창(서버 `care.profile_updates`).
- **지원·복구 agent** (`ai/guardian_ai/recovery.py`), 로그인 채팅 500 오류(import 누락) 수정.
- **앱 디자인 = web-prototype** (아래 구조).

**사용자 정보 구조 (2026-10-08, 다음 작업의 기준)**:
- 한 곳: 서버 `user_profiles`·`user_places`(+ `emergency_contacts`). AI·앱 프로필 화면·서버 경고가 모두 여기를 본다.
- AI 읽기: 로그인 토큰 uid = 요청 user_id 일 때 `tools.get_user_profile`(읽기 전용 DB 계정). DB 기본값(보통·아니오)은 기준으로 쓰지 않음.
- AI 쓰기: 답한 뒤 백그라운드 `OpenAIMemoryExtractor` → `profile_sync.ProfileWriter`가 **사용자 본인 토큰**으로 `POST /api/v1/user`·`/user/places`,
  반영한 것은 `POST /api/v1/user/profile-updates`(`care.profile_updates`)에 기록. 값이 다르면 덮어씀(직업도 통째로 — 이월 항목). 시연 모드 대화도 반영.
- 앱: `AccountSync.pullProfile`(앱 시작·프로필 화면·AI 대화 8·20초 뒤)로 서버 값을 화면 값으로, 올릴 때는 바뀐 칸만(`server_profile_base`).
  `profilePatch`가 화면 값 → 판단용 칸(직업 코드 fisher 등, 시각·청각, 동반자, 혈액형, 비상 연락처). `ai_memory.store`는 쓰지 않음(데이터만 남김).

**앱 디자인 구조 (2026-10-08)**: `app/lib/ui/gk_theme.dart`(GK 색·경보 4단계·테마)·`gk_widgets.dart`(GkCard·GkPill·GkSideNav…),
Pretendard 줄인 글꼴(`app/assets/fonts`), 메뉴 4개(대시보드·AI 대화창·사용자·방재단 현황) + 119 + 머리줄(main.dart `Shell`·`StatusLine`).
태풍·지원 및 복구는 대시보드 카드, 선제 경고는 알림 종. 배치까지 바꾼 화면: 대시보드·AI 대화창·사용자·대피 확인 창·로그인. 나머지는 테마만.
화면 확인 방법: gstack `/browse` 스킬이 이 환경에 없음 → `npx -y playwright@1.48.2 screenshot --channel chrome --viewport-size "1440,900" --wait-for-timeout 7000 <URL> out.png`
(크롬 headless `--screenshot`은 페이지 전환 중에 찍혀 화면이 밀려 보임). 예시 데이터 모드 웹: ASCII 복사본에서 `flutter build web` → `python3 -m http.server`.

**다음 할 일 후보 (사용자에게 고르게)**:
1. **사용자 확인**: 웹에서 로그인 → 새 디자인(실시간 데이터 대시보드) · AI에게 "72살이고 무릎이 안 좋아요" → 20초 뒤 프로필·수집 정보 창 ·
   "태풍 피해 지원받을 수 있어?"(직업 넣고) 확인.
2. **팀 공유** (이월 항목 "조하린·김다인 공유" — 10-07~08분 추가됨, 특히 앱 디자인·메뉴 변경).
3. 디자인 남은 것: 방재단 현황·태풍·길찾기 화면 배치, 앱 '지원 및 복구' 화면을 서버 `/support-programs`로(지금 목업), AI 답 카드(card) 표시.
4. 지원·복구 데이터 보강(소상공인·어선 복구·피해 신고 절차 — 공식 출처로 시드 추가, A 레인 파일) — 사용자가 "일단 있는 데이터로" 결정했음.
5. B4 선제 경고 메시지 함수(A5용) / B13 방문 우선순위 / B12 음성 대피 확인(음성 키 결정 필요) / B11 판정 마무리.
6. 작은 것: 직업을 덮어쓰기 대신 추가로(사용자 결정 필요), 프로필 '자주 방문하는 장소' 글자 칸을 '내 장소'로 합치기(제안만 함).

### (이전) B7 마무리: 경사 규칙 확인, 완료 처리
완료 기준(B7): **같은 목적지에 프로필별로 다른 경로를 반환한다.** 규칙·재계산·AI 연결 끝, 고도는 국토지리정보원
**공개DEM 90m**(도엽 35903, EPSG:5179, 2025)을 적용했다(2026-09-26). 빈 곳은 SRTM으로 채움.
1. 90m라 짧은 골목 경사를 못 잡는다: 남쪽→서쪽 언덕 경로(35.98,129.56 → 35.995,129.545)에서 세 유형 모두
   max_slope 31%(출발·도착 근처 피할 수 없는 구간으로 추정). 시간·거리는 유형별로 다르다(성인 3.2km 38분, 노약자 3.4km 54분).
   유형은 성인·노약자 둘뿐(휠체어 제외, 2026-09-26 사용자 결정).
   → 완료 기준은 충족. 사용자에게 B7 완료 처리 여부를 묻는다(라이브 타임라인 포함).
2. 5m DEM을 구하면(이월 항목) `graphhopper/dem/ngii/`의 90m 파일을 바꾸고 `build_dem.sh` → `docker compose restart graphhopper`,
   `route/guardian_route/profiles.py` 노약자 경사 배수(×0.5·×0.2, 기준선은 1/18·1/12로 확정 2026-10-02)와 계단 배수(0.5)를 실제 경로를 보며 조정.
- 이후 후보: B3(A1·A3 확인, LLM은 OpenAI gpt-6-luna로 전환 완료) 또는 B4(재난 agent 확장 — 위치·경로 agent가 `request_route`·`route_profile` 사용).
- 위험 구역은 지금 항상 피한다(Risk engine 활성 판정과 연결은 A3·A4 이후). A7 적재 후 `hazards.py`에 PostGIS 읽기 추가.

- **배포 VM (2026-10-01)**: `guryongpo-safety-agent` · e2-medium · asia-northeast3-b · Ubuntu 22.04 · 50GB · 스왑 2GB.
  계정 minecraftjykim@gmail.com, 프로젝트 "My First Project"(`project-265888b6-2837-43d6-9d8`) — 팀 프로젝트 아님(사용자 결정: 유지).
  접속 `ssh jongyeonkim@<외부IP>`(임시 IP 34.64.177.195), 코드 `~/guryongpo-safety-agent`, 실행 `docker compose -f docker-compose.yml up -d --build`.
  B10 남은 것: 고정 IP 예약 → Caddy·도메인(없으면 nip.io)·HTTPS, 이 프로젝트 예산 알림, 배포 스크립트(pull + 재빌드).
  **VM `.env`는 맥 `.env`와 다르다 (2026-10-01~)**: `AI_DB_PASSWORD`가 VM에서 만든 48자 무작위 값(출력·저장 안 함).
  맥 `.env`를 VM에 다시 복사하면 AI의 DB 접속이 끊긴다 → 바뀐 키만 VM `.env`에 `sed`로 넣거나, 복사 후
  `AI_DB_PASSWORD`를 새로 만들고 `exec db sh /docker-entrypoint-initdb.d/07_ai_readonly.sh`로 계정 비밀번호도 맞춘다.
  `AI_MEM_DB_PASSWORD`(08, 2026-10-02)도 같은 방식의 VM 전용 48자 값.
  `DB_PASSWORD`(메인 계정)도 2026-10-04 VM 전용 48자 값으로 교체(ALTER ROLE + .env). VM `.env` 백업은 `~/backups/env-*.bak`.
  **2026-10-04 B10**: 고정 IP `guryongpo-ip`(34.64.177.195) 예약, Caddy(`deploy/Caddyfile`, profile deploy) → https://34-64-177-195.nip.io
  (Let's Encrypt). VM `.env`에 `DEPLOY_DOMAIN`·`COMPOSE_PROFILES=deploy`·`CORS_ORIGINS`·`API_INTERNAL_TOKEN`·`KAKAO_REST_KEY`·`DATA_GO_KR_KEY` 추가.

## 이월 항목 (끝나면 지운다)
- [ ] **VM 시험 대피 상황 지우기 (2026-10-09 생성)**: `care.incidents` note='b13_test'(시연 가구 12곳 대상, 도움 요청 2·대피 완료 1, 알림 안 감).
      사용자 확인 끝나면 VM에서 `DELETE FROM care.incidents WHERE note = 'b13_test';`(대상 행은 CASCADE). 초대 코드 1회용(responder, 11-08 만료) 발급함.
- [ ] **실제 로그인으로 확인 안 한 것 (2026-10-08)**: 대화 → 서버 프로필·수집 기록 반영(테스트 계정·dev 토큰으로는 VM 확인함),
      지원·복구 agent(웹), 새 디자인의 실시간 데이터 대시보드. 재난문자 카드는 SAFETY24 키 전이라 보통 위험 판정 경고/"수집 연결 전".
- [ ] **조하린·김다인 공유 — B13 (2026-10-08, 사용자 허락으로 A·C 파일 수정)**:
      조하린(A) — `server/app/priority.py`(새, B13 순서) · `incidents.py` TARGETS_SQL에 `in_area`·`user_profiles` 장애 칸 + 대상에 `in_area`·`disabilities` ·
      `routers/admin.py` `default_rank`·`STATUS_ORDER` 삭제 → `priority.rank`, GET 상세·지도에 `lat`·`lng` · 명세(PriorityReason 예시, IncidentTarget, 정렬 설명).
      영역 밖으로 이동한 앱 사용자는 명단에서 빠짐(요약 수는 그대로). 지적장애(cognitive)·의료기기·고령·독거는 '장애'에 안 넣음 — 사용자 결정.
      김다인(C) — `live_api.dart` `incident(id, lat, lng)`, `patrol_screens.dart` 내 위치(GPS·지도 선택일 때만) 전송·규칙 설명 줄·근거 대체 문구, `c8_test` 기대값.
      + (10-09) 방재단 현황 화면 = 일반 대시보드(`Dashboard`/`DisasterDashboard`에 `title`·`extraPolygons`·`extraMarkers`·`beforeMap`·`afterMap` 추가) + 지도 위 사람 아이콘(`_peopleMarkers`, 대상은 사람+순위 숫자), `_PatrolMap` 삭제.
- [ ] **조하린·김다인 공유 — 10-07~08 추가분**:
      조하린(A) — `care.profile_updates` 표(`db/init/01m_v0_6_profile_updates.sql`)·API `/api/v1/user/profile-updates`(GET·POST·DELETE)·명세,
      `alerts/messages.py` 어업 판단이 'fisher, other'도 인식, 앱이 이제 직업을 코드(fisher·merchant·farmer·office·student·other)로 보냄·비상 연락처를 `/user/contacts`로,
      AI가 사용자 토큰으로 `POST /api/v1/user`·`/user/places`를 부름, `dashboard`·`geocode`가 `optional_user`(로그인 강제라 다시 막을지 결정 필요).
      김다인(C) — **앱 디자인 전체 변경(web-prototype)**: 메뉴 4개로(태풍·선제 경고·지원 및 복구가 메뉴에서 빠짐), `lib/ui/`, Pretendard, 대시보드·AI·사용자 화면 배치,
      로그인 강제·익명 없음, `account_sync.dart`(pullProfile·바뀐 칸만 올림·profilePatch 번역), 'AI가 기억한 정보' 카드·`ai_memory.dart` 삭제 → `profile_refresh.dart`.
- [ ] **조하린·김다인 공유 (2026-10-05, 사용자 허락으로 A·C 코드 수정)**:
      조하린(A) — `server/risk/demo.py`(시연 계산, DB 저장 안 함)·`/api/v1/demo/*`·`app/widgets.py`(/dashboard 실데이터)·`/support-programs`·
      `hazards.py` AWS id 버그(`aws_816`)·`layers.py` 침수 격자 SQL·`households.list_demo`·`simulate.py` 시연 가구 14곳·`users.py` app_state·명세 갱신,
      침수 반경(100/150/300/500m) 근거 메모.
      김다인(C) — 김다인 UI(de5cf30) 위에 실측 데이터(`live_screens.dart`·`disaster_center.dart` 매개변수 demo/simulated/floodGrids…),
      `demo_mode.dart`·`demo_live_api.dart`·`origin_picker.dart`·`custom_route.dart`·`account_sync.dart`, 라우터 `/boot` 리다이렉트, 지도 구룡포 제한(contain).
- [ ] **방재단 초대 코드**: 2026-10-05 GRY-83S3-B7HA (responder, 1회, 2026-11-04 만료) 발급 — 취약 가구 정보 접근 권한이므로 개인적으로만 전달.
      새 코드는 VM에서 `/api/v1/internal/invites`(API_INTERNAL_TOKEN, 외부 차단 — VM 안에서 curl).
- [x] **C8 공유·확인 (2026-10-05)** — VM 배포·웹 배포 끝(2026-10-05). 공유는 위 항목으로 합침: 김다인에게 `app/lib/patrol_screens.dart`(LiveHouseholdScreen·LiveResponderScreen을 live_screens.dart에서 옮김, 방재단 화면은 responder·admin만 — 시연 store도 caregiver 제외), 조하린에게 `db/init/10_seed_ports.sql`(ports 표, data_sources `ports_b11`)·명세 SeaRoute* 확정.
      **VM 배포 안 됨** (커밋 5258af2·9610d72는 푸시함, 이 맥은 VM ssh 키 없음): VM 접속되는 맥에서 VM `./deploy/deploy.sh`(loader가 10_seed_ports 적용, route 재빌드)
      → 맥에서 `./deploy/push_web.sh` → 초대 코드(`/internal/invites`, role responder)로 방재단 역할 → 방재단 대시보드·방문 기록·가구 등록 화면 실제 로그인으로 확인
      (로컬은 secrets/firebase-admin.json 없어 로그인 필요한 화면이 401).
      앱 기존 테스트 8개 실패는 C8 전과 같음(disaster_center 2·location 3·remote_mapping 1·route_and_places 2 — 1개는 10분 멈춤) → C 확인 필요.
      이 맥에 Flutter SDK 설치함(`~/development/flutter`, 3.47.6, PATH 미등록).
- [ ] **B11 마무리**: 판정 로직은 나중에 다시 수정(사용자 2026-10-05). 방파제 통과 문제는 해결(아래 작업 기록) — 남은 후보: 바닷길 여유 거리(15m)·격자(25m) 조정,
      수심·암초 미반영, 어항 종류 확인(구룡포항만 국가어항 확인), 이름 없는 포구 2곳(석병리 북쪽·흥환리) 이름 확인, 풍랑 특보는 호출 쪽(앱·AI)이 붙임, AI 위치·경로 agent 연결(`request_sea_route`).
- [ ] **A 레인에 공유**: AI가 risk_assessments·v_latest_observations·weather_warnings·disaster_messages·hazard_zones·shelters·
      medical_facilities·manholes·action_guides·ingest_runs를 읽기 전용으로 직접 읽음 → 컬럼 이름·의미 바꿀 때 B에게 알려 달라.
      `db/init/07_ai_readonly.sh`(B 소유) 추가 사실과 팀원 로컬 DB에 한 번 실행하는 명령도 함께 (README에 적음)
- [ ] 침수 지정 대피소가 데이터에 없음(구룡포 19곳 = 지진해일 17·민방위 2) → A에게 확인 요청, 그 전까지 침수 안내는 종류 무관 가장 가까운 대피소
- [ ] **휠체어 경로 유형 다시 검토** — 2026-09-26 사용자 결정으로 제외(지금은 휠체어 이용자 → 노약자 경로).
      되살릴 때 참고: 이전 규칙은 계단 ×0(통행 불가), 산길(path·track) ×0.1, 경사 ≥5% ×0.3·≥8% ×0.05(경사로 기준 1/12≈8%),
      속도 ×0.7 (커밋 7407ed3의 route/guardian_route/profiles.py). 검증에서 나온 쟁점: ① 계단 금지 때문에 짧은 계단 대신 급경사로
      돌아가는 경우, ② 급경사와 산길이 부딪칠 때 포장도로 우선(사용자 의견: 산길 벌점을 급경사보다 세게),
      ③ OSM 계단 정보가 빠져 있을 수 있음(구룡포 5곳만 표시) → 시연 경로 계단 로드뷰 확인·임시 데이터 추가,
      ④ 90m 고도로는 8% 기준 판정이 부정확 → 5m DEM 이후가 적절, ⑤ 위험 구역 벌점(×0.001)이 휠체어 최악 벌점 조합보다
      10배 이상 센지 (`test_hazard_penalty_outweighs_every_profile_penalty`). 사용자 정보 `Mobility.WHEELCHAIR`는 남아 있다.
- [ ] **국토지리정보원 DEM 5m 구하기** — 지금은 공개DEM 90m(누구나 받는 것, SRTM과 간격이 같음). 국토정보플랫폼(map.ngii.go.kr)에서
      "공개DEM" 말고 수치표고모형 5m 항목·공급 신청(승인 필요할 수 있음) 확인. 받으면 B7 다음 세션 시작점 2번대로 교체.
      다운로드에 INNORIX-Agent 필요(국토정보플랫폼 공지 notice_id=1408, Mac·Windows·Linux)
- [ ] 공개DEM 북쪽 도엽 추가 — 35903은 북위 36.00°까지라 도로망 북쪽 4km(36.00~36.04)가 빠져 SRTM으로 채워짐.
      구룡포 시가지(약 35.99°)는 덮인다. 5m를 구하면 함께 해결
- [ ] **OpenAI 전환을 로컬·VM 컨테이너에 반영** — 키 넣음·live 13/13 통과(2026-10-01). 남은 것: 로컬 `docker compose up -d --build ai`,
      VM은 `.env` 복사(해시 비교) 후 `docker compose -f docker-compose.yml up -d --build ai`
- [ ] OpenAI 월 사용 한도 — 키가 다른 사람 것이라 대시보드 한도는 보류(사용자 결정). 대신 `usage.py`가 예상 비용을 세고
      월 20만 원의 50·80·100%에서 경고. 키 주인에게 전용 프로젝트·한도·새 키를 부탁하는 안은 열어 둠
- [ ] B3 환각 검증 테스트 결과를 보고 부족한 단계만 `gpt-6.1-sol`로 올릴지 결정 (지금 전 단계 gpt-6-luna)
- [ ] A와 DB 조회 방식 합의 (읽기 전용 직접 조회 vs FastAPI 경유, `agent-design.md` 7절 3번) — 미배정
- [ ] C와 카드형 표시 합의 — `/api/chat` 응답에 `card`(headline·chips·steps·sources·call_emergency)·`voice_text` 추가됨(B5, `agent-design.md` 8절). 앱 화면은 아직 글만
      (새 디자인 AI 대화창도 글 + 경로 버튼만 — 프로토타입처럼 말풍선 안 카드로 보여 줄 수 있음)
- [ ] **음성 대화 — 나중에** (사용자 결정 2026-10-03, B12 전에 다시 결정). 시작할 때 GCP 음성 키: Speech-to-Text·Text-to-Speech API 사용 설정 + 서비스 계정 키 → `secrets/gcp-voice.json`. VM에도 같은 파일(B10과 함께)
- [ ] 조위(만조) 데이터: 기획서·목업은 쓰지만 수집 목록에 없음 → A에게 제안 (tools에는 `tide` 종류만 있음)
- [ ] 조하린 GCP·GitHub 권한, 팀원 로컬 실행 확인 — 사용자가 직접 진행
- [ ] **로그인(2026-10-04) 공유·확인**: C(김다인)에게 앱 ID `kr.guryong.guardian` 변경·`firebase_options.dart`·`login_screen.dart`, A(조하린)에게 `users.py` ENSURE_SQL(is_anonymous 갱신)·앱이 이제 `POST /api/v1/user` 호출. 안드로이드: 빌드 확인 못 함(맥에 SDK 없음) — Google 로그인 시험할 PC의 디버그 SHA-1을 Firebase 안드로이드 앱에 등록. 브라우저·시뮬레이터에서 Google 팝업 로그인 실제 확인 필요
- [ ] **해커톤 끝나면 고정 IP 해제** — `gcloud compute addresses delete guryongpo-ip --region=asia-northeast3 --project=project-265888b6-2837-43d6-9d8` (VM을 지운 뒤 남겨 두면 요금)
- [ ] **C에게 알리기**: 김다인 커밋(e2f6abf·629dccf) 이후 앱이 컴파일 안 되던 2곳을 B10 배포용으로 최소 수정(40b3faa, 사용자 승인). 앱 테스트 5개 실패(거리 추정 0.1→0.2, 경로 문구 '노약자', location_test 3개 StateError) — C 확인 필요
- [ ] 사용자 정보 정식 서비스 전: 대화 내용을 프로필에 반영한다는 동의 문구(앱), `ai_memory` 스키마·`AI_MEM_DB_*` 계정 정리 여부(지금은 데이터만 남김, 사용자 결정)
- [x] A의 `users`·`user_profiles`와 AI 기억 동기화 → **서버 프로필 하나로 결정·구현** (2026-10-08)
- [ ] **AI가 직업을 들으면 통째로 덮어씀** (예: '어업, 자영업' + "학생이에요" → '학생'만) — 추가로 바꿀지 사용자 결정 필요
- [ ] **지원·복구 데이터 부족**: `support_programs` 9건뿐 — 자영업(소상공인)·어선 피해 복구·피해 신고 절차 없음 → AI는 "등록된 제도 없음, 읍면동 문의".
      앱 '지원 및 복구' 화면(`RecoveryScreen`)은 목업 문구 그대로라 AI 답과 다름
- [x] 대피소 데이터: **지금 DB의 19곳만으로 진행** (사용자 결정 2026-10-02, A 레인 요청 안 함).
      지진해일 실외 17 + 지하주차장 2뿐이라 침수 때 실내 대피처가 없다 → 앱·AI는 위험 영역 안·침수 중 지하를 빼고 안내
- [ ] 2026-10-02 QA 남은 것 (심각 1~3번은 해결): 노약자 경사 31% 구간(90m DEM 한계), 의료시설 5곳 모두 17~20km 밖(A),
      화면 1분 새로고침 없음, ~~GPS 미반영~~(2026-10-02 해결, 구룡포 안만), 서버 꺼짐 표시·알림 상세·시설 상세 오류 문구, 프로필 고정 문구,
      빈·엉뚱한 질문 답(B5 의도 검증으로 완화), 로컬 `API_INTERNAL_TOKEN` 없음
- [ ] **A 레인 요청 (생활안전 행동요령)**: 자외선·미세먼지·폭염 대응요령 원문을 action_guides에(기상청·환경부 출처, hazard uv·fine_dust·ultrafine_dust). 들어오면 행동 권고가 자동으로 붙임. 사용자가 A에 전달
- [ ] 대피 경로가 너무 김: 침수 경보 원(반경 300m)을 돌아가느라 직선 323m 대피소가 2.7km·33분, 노약자 3.9km·63분 (2026-10-03 침수 시연) → 수직 대피(가까운 건물 고층) 안내나 원 크기·회피 강도 조정 검토
- [ ] 응답 시간 (목표 텍스트 15초·음성 20초, 2026-10-03 결정): 대부분 7~19초, 검증 재시도 1회면 30~35초 → 재시도 때 전문 agent 결과 재사용(데이터 재수집 없이 문장만 다시) 검토
- [ ] 판단 로직 live 테스트(`test_tree_live.py`)는 '위험 영역 안'만 강제해 판정 엔진의 '정상'과 어긋난다 → 가끔 검증 재시도. 실제 데이터는 같은 판정에서 나와 어긋나지 않음. 시연 시나리오(A `heavy_rain_flood`)로 다시 재 볼 것
- [ ] J1 이후 앱 연결 남은 것: 알림을 `/api/v1/alerts`로(A5 실구현 후), 등록 장소 위험·`/user`·`/device-token`(Firebase 웹 앱 등록 필요), `/route/check`(C5), 음성(B5). C 레인과 공유
- [ ] 로컬 `.env`에 `API_INTERNAL_TOKEN` 없고 `API_AUTH_MODE`가 dev가 아니라 `/api/v1/internal/simulate`가 막힘 — 시연 전 토큰 설정 (오늘은 api 컨테이너 안에서 `risk.simulate.apply` 직접 호출)

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
- 2026-09-26 유형 규칙 변경(사용자 결정): 휠체어 유형 삭제(휠체어 이용자는 route_profile에서 elderly), 성인은 경사 반영 안 함(그대로), 노약자는 같은 경사면 계단 선호 — 계단(×0.3)에는 경사 벌점을 빼고(if/else_if), 급경사 도로(≥10% ×0.2, ≥6% ×0.5)보다 계단이 싸게. 33개 경로 재검증: 노약자 계단 이용 성인과 같음(구룡포공원 계단 포함), 계단 아닌 ≥10% 도로 합계 10.3km → 6.3km, 노약자가 성인보다 급경사가 많은 경로 0건. 위험 구역 벌점이 모든 유형 벌점보다 10배 이상 센지 검사하는 테스트 추가. route 34 + live 6, ai 30.
- 2026-09-26 휠체어 경로 유형을 이월 항목(나중에 고려)으로 기록 — 이전 규칙과 검증 쟁점 포함.
- 2026-09-27 노약자 계단 배수 0.3 → 0.5: 기본 도보 모델이 계단을 3km/h(도로 5km/h)로 계산해 0.3이면 같은 경사·같은 길이에서 계단이 주택가 급경사 도로보다 1m당 약 11% 비쌌다(선호 미보장). 1m 비용 부등식 테스트 추가. 참고: GraphHopper average_slope는 5비트라 31%가 최대(그 이상도 31로 저장), 8m 미만 구간은 경사 0.
- 2026-10-01 B10(진행): e2-medium VM에 스왑 2GB·Docker 29.8/Compose v5.5 설치, 저장소 clone, `.env`·firebase 키·OSM·DEM(dem-hgt) 복사(해시 확인, 600 권한), 서버 모드로 6개 서비스 healthy. 실측 메모리 합계 약 0.6GB(graphhopper 364MB) → e2-medium 충분. 8000–8002는 GCP 방화벽으로 외부 차단 확인. 기상청·포항 DT 키 반영 — 일부 API 활용신청 미완, 생활안전24 키 없음(이월 항목).
- 2026-10-01 LLM을 Gemini → OpenAI `gpt-6-luna`로 전환(사용자 결정, 가성비 기준 — 입력 $0.1·출력 $0.5/1M, 질문당 약 4원 추정). `llm.py` `OpenAIClassifier`(Responses API 구조화 출력, 추론 effort low, temperature 없음, SDK 재시도 끔), `.env.example` `OPENAI_*`, 테스트 가짜 클라이언트 교체. 오프라인 30 통과, live는 키 받은 뒤.
- 2026-10-01 OpenAI 사용량 경고: `usage.py`(응답 usage → 모델 단가·환율 1,400원으로 예상 비용, 월별 파일 누적, 월 예산 `OPENAI_BUDGET_KRW`=20만 원의 50·80·100%에서 WARNING, 호출은 막지 않음), `GET /api/ai/usage`, compose `ai-data` 볼륨. live 라우팅 13/13 통과 — 13회 입력 10,944·출력 717 토큰, 약 2원(호출당 0.16원). 테스트 34 + live 13.
- 2026-10-01 B3(진행) DB 직접 조회(사용자 결정, 기획서와 같음): `db/init/07_ai_readonly.sh`(guardian_ai 계정 — SELECT만, 계정·접속 두 겹 읽기 전용, 조회 3초 제한), `ai/guardian_ai/db.py`(첫 조회 때 여는 커넥션 풀), `tools.py` 9개 tool을 실제 SQL로 교체(실패 시 available=False), `RiskLevel`을 DB 5단계로·`ActionGuide`를 action_guides 행 형식으로, alert 경로 agent는 경보 이상(critical 포함). 로컬 DB 초기화(사용자가 직접 볼륨 삭제) 후 표 36개·대피소 19·산사태 488·행동요령 51 확인. 테스트 49 + db 2(쓰기 차단 두 겹 확인) + live 13. 발견: 침수 지정 대피소 없음.
- 2026-10-01 B3 침수 agent·환각 검증: `flood.py`(코드가 DB 수집·근거 생성, LLM은 문장만, 실패 시 템플릿, 위치 없으면 구룡포읍 중심 명시, DB 장애 시 "확인 불가"), `verify.py`(숫자 규칙 검사 — 단위 변환·반올림 허용 → LLM 내용 검사, 장애 시 숫자 결과만), `llm.py` `OpenAIWriter`·`OpenAIFactChecker`(`OPENAI_VERIFY_MODEL`). 관측 tool이 시연 모의값을 6시간 우선(판정 엔진과 맞춤 — 아니면 판정 "경보"인데 근거 0mm). A의 heavy_rain_flood 시나리오로 /api/chat 왕복 확인(질문당 4–6초), 끝나고 clear. live 틀린 답 주입 10/10·맞는 답 3/3 (2회). 테스트 71 + db 2 + live 26. 누적 OpenAI 약 8원.
- 2026-10-01 B3 완료 처리(사용자 결정). 라이브 타임라인 B3 체크(12/30). GitHub 푸시. VM: `.env` 복사 후 AI_DB_PASSWORD만 VM 전용 무작위 값으로, git pull(d91b74c), 07 스크립트로 읽기 전용 계정, ai 재빌드 → DB tool·쓰기 차단·/api/chat(침수 agent LLM + 환각 검증 통과) 확인.
- 2026-10-01 지연 측정(로컬, 실제 OpenAI·DB): 질문당 OpenAI 3회 직렬(분류 ~3초·작성 ~3초·환각 검증 ~3–4초), DB 0.02초. 재시도 10건 중 3건 → 17–22초. 확인된 원인: 근거 목록에 기준 위치가 없어 검증기가 "집" 언급을 근거 없는 말로 봄(시스템 빈틈) → `flood.py` 근거에 "기준 위치" 추가, 작성기와 같은 이름(`location_text`). 수정 후 20건 재시도 0, 평균 8.1초(최대 11.5초), 틀린 답 주입 10/10 유지. 남은 개선 후보: 재시도 때 분류 생략, 검증 effort low, 스트리밍(B5). B4·B5로 호출이 7회가 되면 15–20초 → B5 전에 목표 시간 정하기.
- 2026-10-01 경로 시연 1 — 위험 구역 회피 검증: `route/scripts/avoid_demo.py`(운영 `RouteService`에 메모리 위험 구역 주입, 실제 GraphHopper). 출발·도착 3쌍 × 가상 침수 구역 6개(경로 위 4·대조군 2)를 무작위로 켜고 끄기 15회 + 경계 사례(출발지가 구역 안) 1회 → **16/16 통과**(켜진 구역 통과 없음, avoided 일치, 경로 밖 구역만 켜지면 기본 경로 유지, 피할 수 없으면 still_inside로 알림). 응답 10–70ms. 회차별 PNG·모아보기·GIF·결과 표는 `route/out/avoid_demo/`(gitignore). 참고: 우회가 기본보다 짧은 회차 2건(−59m, −17m) — GraphHopper는 거리가 아니라 시간×도로 선호도로 고르기 때문. 사용자 유형별 검증은 다음.
- 2026-10-02 노약자 경사 기준선을 공식 자료로 교체(사용자 결정: 배수는 그대로): ≥6%→**1/18(5.56%) 초과**, ≥10%→**1/12(8.33%) 초과** — 국토해양부 「보도 설치 및 관리 지침」(2011.07) 원문(보도 종단경사 1/18 이하, 곤란 시 1/12, 1/12 = 교통약자 통행 최대). `profiles.py` `SLOPE_SIDEWALK_MAX`·`SLOPE_ACCESSIBLE_MAX`, 상수 이름 `ELDERLY_OVER_SIDEWALK`(×0.5)·`ELDERLY_OVER_ACCESSIBLE`(×0.2). 정수 경사 저장이라 실질 6% 이상·9% 이상(9%가 강한 벌점으로 이동). 시가지 21경로 비교: 7개 경로 변경, 9% 이상 도로 4,184→3,769m(−10%), 총거리 +1.3%. 테스트 route 35 + live 6. 배수(×0.5·×0.2·속도 ×0.75·계단 ×0.5) 근거 조사 결과: 속도는 경찰청 0.8 기준, 선호도 배수는 Valhalla 설계값(연구 근거 없음)뿐 — 보행 경로 선택 관찰 연구 조사는 이월.
- 2026-10-02 사용자별 기억(사용자 계획 승인): 단기 = LangGraph `PostgresSaver`(대화 안, 재시작해도 이어짐), 장기 = `PostgresStore`(사용자 사실·대화 요약). `db/init/08_ai_memory.sh`(스키마 ai_memory + 전용 계정, public 권한 없음), `memory.py`(DB 못 닿으면 메모리 대체, 대화 주인 확인, 불러오기 → 빈 프로필 칸·분류 프롬프트·침수 근거, 저장 → 백그라운드 `OpenAIMemoryExtractor`), `remember` 기본 켜짐(사용자 결정), `GET/DELETE /api/ai/memory/{uid}`. 로컬 왕복: 무릎 발언 → 새 대화 분류 이유에 "보행 불편도 고려", AI 재시작 후 기억·대화 유지, "거기까지"를 이전 대화로 해석. 발견·수정: 재시작 직전 백그라운드 저장 유실 → 종료 때 대기(`close()`·lifespan), 이어지는 대화가 요약을 덮어씀 → 기존 요약을 넘겨 넓힘. 테스트 ai 87 + db 4 + live 32(추출기 6/6: 직접 말한 사실만, 추측·재난 수치 저장 안 함).
- 2026-10-02 단기 기억을 InMemorySaver로 되돌림(사용자 결정): 실측 질문 1개당 체크포인트 약 12개·이전 질문 근거까지 DB에 누적, 위치·건강 정보가 상태째 영구 저장 → 대화 기억은 서버 메모리 + 마지막 문답 후 60분 만료(`CONVERSATION_TTL_MIN`, 만료 대화 지우기, 만료·모르는·남의 id는 새 대화), 장기 기억만 PostgresStore. 로컬 확인: 재시작 후 사용자 기억 유지·옛 대화 id는 새 대화, 새 대화에서도 "거기"를 대화 요약(장기 기억)으로 대피소로 해석. 테스트 ai 89 + db 4. 로컬 ai_memory에 오전 PostgresSaver 시험 때 생긴 checkpoint 표 4개(테스트 대화 데이터)가 남아 있음 — 정리 필요.
- 2026-10-02 정리·배포: 로컬 ai_memory의 옛 checkpoint 표 4개 삭제(사용자 허락), 커밋 5bb0c9a(회피 시연·경사 기준선)·b08d49d(AI 기억) 푸시. VM: `.env`에 AI_MEM_DB_*(VM 전용 무작위 비밀번호)만 추가(맥 .env 덮어쓰지 않음), pull, 08 스크립트, ai 재빌드 → 장기 기억 postgres, 실제 질문으로 보행 불편·나이 저장 확인 후 삭제, 외부에서 8001 접근 차단 확인.
- 2026-10-02 J1 연동(사용자 계획 승인): 앱 `RemoteSafetyRepository`(api 위험도·위험 영역·시설 GeoJSON, ai /api/chat, route /api/route + 위험 구역 이름), 저장소 인터페이스 비동기화·Riverpod FutureProvider, 실서버 모드에서 예시 그리드·가짜 수치 숨김. ai·route에 CORS(`CORS_ORIGINS`). 테스트: ai 90·route 36·app 10 통과, 실서버 확인(평상시 정상·대피소 24곳·노약자 경로, `heavy_rain_flood` 주입 시 경계·알림 2·위험 영역 8·AI 답변 실제 수치 → clear). AI 답변 끝 "/ location_route_agent stub"은 B4에서 해결.
- 2026-10-02 QA 심각 문제 수정(사용자 계획 승인): ① 경로 서버가 임시 파일 대신 판정 엔진의 침수·산사태 영역(주의 이상, `/api/v1/risk/areas`, 60초 캐시)을 피함, 맨홀 회피 제거(사용자 결정), GraphHopper가 구역을 가로지르는 도로를 못 보는 문제(긴 구간이 작은 구역을 꼭짓점 없이 통과) → 받은 경로를 직접 검사해 그 구역만 50·100m 넓혀 재요청. 침수 시연 실측: 경로 76개(주민·관광객 × 성인·노약자 × 대피소 19) 중 피할 수 있는데 지나는 경로 0, 중간 통과 0(출발·도착 쪽만 최대 245m). ② 위치·경로 agent(`location.py`): 갈 만한 대피소(위험 영역 밖, 침수 중 지하 제외) + 실제 경로, 구현 전 agent 'stub' 문구 제거. 침수 agent도 같은 대피소 규칙. ③ 앱: 같은 규칙으로 '경로 안내' 대피소 선택·목록 경고, 가까운 경로 = 성인 프로필. 테스트 ai 99·route 42·app 12 통과.
- 2026-10-02 위치·경로 agent 보완(사용자 계획 승인): ① 채팅 응답에 `route`(목적지·geometry) → 앱 AI 답 "지도에서 경로 보기"로 대시보드 지도에 그대로 그림 ② 목적지 지정 — 분류기가 `destination`·`mobility_limited`를 같은 호출로 뽑고(규칙 대체), `find_place`(등록 장소 → DB 시설 → 카카오), 위험 영역 안 목적지는 안전한 대피소로 경로 ③ 같은 질문의 보행 불편 → 노약자 경로, 앱 '보행 능력' 반영. 앱 장소 등록 실제 저장(지도에서 선택, 기기 저장, AI profile에 home·frequent_places). 실측: 충혼탑(DB)·집(등록) 경로, 무릎 질문 → 노약자, 침수 중 여의주타워 질문 → "가지 마세요" + 초등학교까지 225m 경로. 카카오는 키 없어 미확인. 테스트 ai 114·app 16.
- 2026-10-02 카카오 장소 검색 실측: 구룡포항·일본인 가옥거리·해수욕장·과메기문화관·시장 정확, 서울역은 범위 밖 처리. /api/chat: 구룡포항 666m 8분, 가옥거리 1160m 14분, 침수 중 "구룡포항 가도 돼?" → 가지 말라 + 초등학교 225m 경로.
- 2026-10-02 앱 GPS 위치(사용자 요청): `location_service.dart` + `userLocation` provider — 구룡포 일대 안 GPS면 위험도·시설·경로·AI 질문을 그 위치로, 밖·권한 거부면 예시 위치(상단 줄에 이유). 30m 넘게 움직일 때만 다시 계산, 지도 GPS 버튼·지도 탭 선택. Android·iOS 위치 권한 추가. 같은 날 웹 오류 2건 수정: 큰 창에서 지도 제한(contain → containCenter), 웹에서 polyline `~` 부호 문제. 앱 테스트 23(크롬에서도 통과).
- 2026-10-03 B4(사용자 계획 승인): `specialists.py` 산사태·강풍태풍·생활안전 agent(판정 엔진·취약지역·강수·바람·특보·자외선, 확인 불가 정보도 근거로), `action.py` 행동 권고(규칙이 원문 고름 → LLM이 사용자 맞춤 '지금 할 일', 원문은 검증 근거, 119 규칙)·재난 단계(전/중/후 24시간/평시). `ChatResponse.call_emergency`. 실측: 산사태·태풍(어업인)·자외선·침수 시연(관광객 2회 연속 통과 9~11초, 78세 보행 불편 → 119 첫 할 일). 고친 것: 확인 불가 정보 근거 누락(자외선 검증 3회 실패), 호우만 있을 때 산사태 정상 누락, 관광객 장소별 원문이 앞에. 테스트 134.
- 2026-10-03 행동 권고를 사용자 판단 로직으로 재구성: `action.decide`(재난 전·평시/중/후 → 위험 지역(`hazards_at`, 판정 불가 → 위험) → 이동 가능·피해 유무(분류기 `can_move`·`damage`, 규칙 대체) → 119 맨 앞/대피소 경로/질문 하나 + 안내), `get_forecast`(기상청 초단기·단기, 오늘·내일 이름), 응답 `decision_path`·`follow_up`, 평시 정보 질문은 행동 권고 생략, 내용 검사 완화(원문 풀어쓰기·준비 단계 허용). 실측: 내일 비 7초, 태풍 대비+질문 15초, 침수 시연 이동 가능(경로)·갇힘(119 맨 앞)·80세(질문) 14~19초 재시도 0. 외부 API: 기상청 예보·태풍, 포항 DT 대기환경 승인 반영(재난문자는 IP 등록 필요 — 나중에). 테스트 145.
- 2026-10-03 B5(사용자 계획 승인 — Google Cloud, 목표 텍스트 15초·음성 20초, 카드형 + 텍스트): 의도 검증을 내용 검사와 한 호출로(사용자 질문·대화 속 사용자 말도 근거), `polish.py` 카드(코드가 근거에서 칩)·600자 넘는 답만 LLM 요약·음성 문장, 다듬은 뒤 숫자 재검증 규칙만 → `polish_feedback`(#3 해결), 노드별 `timings`. `voice.py`(ffmpeg 16kHz → Google STT v1, TTS v1 Neural2 mp3, 10분 캐시) + `/api/voice`·`/api/tts`(키 없으면 503). 앱: AI 대화창 마이크(16kHz WAV) → 받아쓴 질문·답·답 음성 자동 재생, "음성으로 듣기"는 `voice_text`를 `/api/tts`로. 판단 로직 live 11/11. 지연을 줄이며 고친 것: 내용 검사 medium이 10초 제한을 자주 넘어 검사가 빠짐 → low(4초, 같은 문제 잡음), 대피소 선정 기준·'이동 불가 판단 결과'를 근거로, 위험 지역 분기는 코드가 답 맨 앞에 밝힘, 누락·원문 적용 대상은 실패 아님, 작성기가 '주변 사람 도움 요청'을 지어내지 않게, 분류기 실패 시 "걸어갈 수 있어요" 규칙. 실측: 텍스트 대부분 7~19초, 재시도 1회 30~35초. 테스트 ai 160·app 26(크롬 포함). 실제 음성 왕복은 GCP 키 대기.
- 2026-10-03 사용자 결정: 음성 대화 기능(실제 Google 음성 왕복)은 나중에 구현. 코드는 그대로 두고(키 없으면 503, 채팅 영향 없음) B12 전에 다시 정한다.
- 2026-10-03 세션 정리: ai/CLAUDE.md 현재 상태·주요 파일 표(B4·B5 파일, 줄 번호), 루트 CLAUDE.md 음성 상태, 다음 세션 시작점 갱신.
- 2026-10-04 B10(사용자 계획 승인 — nip.io, 웹앱 포함): VM 최신화(35커밋 뒤 → 5295361, DB 백업·loader·재빌드), 카카오·응급실 병상 키 VM 반영(nmc ok), 고정 IP 예약, Caddy·`deploy/deploy.sh`·`push_web.sh` 추가, VM DB 비밀번호 교체·내부 토큰 생성, https://34-64-177-195.nip.io 외부 확인(health 3종 200, 차단 3종 404, http→https, AI 질문 1회), 앱 컴파일 오류 2곳 최소 수정 후 웹 배포(Firebase 웹 설정 없이).
- 2026-10-04 로그인(사용자 계획 승인 — Google+이메일, 웹·iOS·안드로이드, 앱 ID kr.guryong.guardian): Firebase에 안드로이드·iOS 앱 등록, 사용자가 콘솔에서 Google·이메일 켬, `firebase_options.dart`·`auth_service.dart`(익명 계정에 연결, 서버 등록)·`login_screen.dart`, AI user_id = Firebase uid, server ENSURE_SQL is_anonymous 갱신. 앱 테스트 30 통과·5 실패(이전부터), 웹·iOS 시뮬레이터 빌드 성공, VM deploy·웹 배포, REST로 익명→이메일 연결 uid 유지·is_anonymous false 확인. OSM guryongpo.osm.pbf 커밋(7085b8f).
- 2026-10-05 앱 정보 계정 동기화(문제 정리 5번, 사용자 결정: 통째 저장 + 판단용 칸): server `user_profiles.app_state` + `GET·PUT /user/app-state`(A 레인 — 조하린 공유), 앱 `account_sync.dart`(PATCH /user·/user/places·app-state). 서버 195 통과, 앱 새 테스트 5, VM 배포·웹 배포, REST로 기기A 익명 저장 → 이메일 연결 → 기기B 로그인 시 프로필·장소·저장본 복원 확인.
- 2026-10-05 C8(+B11 1차, 사용자 계획 승인): route `POST /api/route/sea`(sea.py — OSM 해안선 육지 다각형, 카카오·OSM으로 확인한 항·포구 12곳, 직선 거리·16방위, 목적지 생략 시 갈 만한 대피소, 경로 엔진 장애 시 해상 안내 유지), DB ports 시드, 명세 갱신 — route 54 통과(새 10). 사용자: B11 로직은 나중에 다시 바뀜 → AI 연결 보류. 앱 `patrol_screens.dart`: 가구 등록 + 별도 민감정보 동의 화면, 방재단 대시보드(responder·admin만, 우선순위 명단·지도·10초 갱신·방문 결과·맡기), 대리 등록, 바다 위 대피 경로. 메모 대화상자 컨트롤러 조기 해제 버그 수정. 앱 테스트 71 통과(새 10, 크롬 통과) · 기존 실패 8개 변화 없음. 로컬 API로 명단→맡기→방문 기록→대피 완료, 등록·동의·철회, 대리 등록 확인. 웹에서 해상 경로 화면 확인.
- 2026-10-05 해상 경로가 육지를 뚫는 문제(사용자 발견) 수정: 무작위 바다 출발 400곳 × 상위 3항구 = 1,200구간 중 467구간이 육지를 지남 —
  ① 좁은 항구의 접안점을 방파제·부두 건너편 격자 칸에 붙임(413) ② 바닷길을 못 찾으면 직선으로 그림(54).
  길찾기 수정은 같은 시각 올라온 19cadaa(육지 안 지나는 칸에 붙이기 + 대각선 이동 검사)를 따르고, 여기서는 ②만 — 못 찾으면 선을 그리지 않음(앱도).
  같은 400곳에서 0구간, 넓은 범위 회귀 테스트 추가. route 57 통과.
  같은 날 시연 모드에 "대피 경보 팝업" 버튼(실제 경보 팝업 그대로, 응답은 기기 시연 기록에만) — 사용자 요청. 앱 C8 14 통과.
- 2026-10-05 방재단 대시보드 시연(사용자 요청): 시연 취약 가구 5 → 14곳(장애인·독거노인, 도로 위 육지 확인, 바다 위였던 2곳 좌표 수정 — server/risk/simulate.py, A 레인 공유),
  방재단 지도에 등록 가구를 대피 상황과 상관없이 장애인·독거노인·기타 아이콘으로 + 필터, 대피 상황이면 대상·영역에 맞춤, 지도 처음 회색(타일 안 받음) 수정(onMapReady fitCamera).
  서버 버그 수정: dev 모드 시연 초대 코드가 역할을 저장하지 않아 앱 방재단 화면이 안 열림(routers/user.py). 앱 DEV_UID(로컬 전용 dev 토큰).
  로컬 확인: 평시 지도 14곳 → 모의 침수 → 대상 4곳 번호·영역 → 방문 기록 → 대피 완료·순위 변경. 서버 198·앱 C8 13(크롬 포함) 통과.
- 2026-10-05 B11 방파제 회피(사용자 요청 — 해상 직선이 구룡포 북방파제를 가로지름): land.geojson에 OSM man_made=breakwater·pier·groyne 추가,
  해상 구간을 육지·방파제에서 15m 떨어진 격자(25m) 최단 경로 → 직선으로 펴서 꺾는 점만(`sea.py` `sea_paths`), 항구는 바닷길 길이 순.
  응답 `sea_leg.path`(인코딩 꺾은선)·`straight_m`·`path_found` 추가, 앱이 그 꺾은선을 점선으로 그림. 요청당 약 0.05초. route 55·앱 C8 11(크롬 포함) 통과, 웹에서 방파제 끝을 돌아 항구 입구로 들어가는 것 확인.
- 2026-10-05 실측 데이터화(사용자 계획 승인 — 자료 없음 표시, 시연 모드 스위치, 서버·앱 모두 내가): ① A 버그 hazards AWS id `816`→`aws_816`(호우·강풍 실측 판정이 처음부터 안 돌던 것, 850fadd) ② server `/dashboard` 실데이터(`app/widgets.py`)·`/support-programs`(817d89f) ③ 앱 `live_screens.dart`(실측 상황판·태풍·복구·방재단·가구 등록)·`demo_mode.dart`(ca54a5a). VM 배포·웹 배포. 실제 태풍 초이완(2627) 경로·예측 표시 확인. **조하린·김다인 공유 필요**.
- 2026-10-05 앱 화면 작업(사용자 요청): 출발 위치 직접 지정(GPS·집·직장·저장 장소·지도·주소, `origin_picker.dart`), 길찾기 — 주소 출발·목적지로 안전 경로/가까운 경로 비교(`custom_route.dart`),
  김다인 UI(de5cf30)를 실측 모드 기본 화면으로(상황판·태풍 정보·선제 경고 알림), 대시보드·경로 지도를 구룡포로 한정(`CameraConstraint.contain`, 태풍 지도 제외),
  첫 접속·새로고침 때 "로그인 정보를 확인하지 못했습니다"(라우터 `/boot` 리다이렉트 + Firebase authStateChanges 대기, c234c75), iOS 시뮬레이터는 CocoaPods 없이(SPM, flutter_tts 제외 복사본).
- 2026-10-05 방재단 시연(사용자 요청): 시연 모드에서 방재단 화면이 서버 DB 시연 가구 14곳(`GET /api/v1/demo/households`)을 보도록, 없으면 앱 안 12곳. 초대 코드 1개 발급(이월 항목).
- 2026-10-05 침수 격자 = 경로 서버가 피하는 침수 영역과 같게(63e8cad): 0.001° 칸을 주의 이상 위험 영역으로 잘라냄(`layers.py` `FLOOD_GRID_SQL`).
- 2026-10-05 시연 데이터 변경(사용자 결정 — 서버에서 계산·시연 모드에만, 호우·침수 + 강풍): 실제 센서 좌표 그대로 측정값만 시나리오 값, 실측과 같은 판정 규칙, DB 저장 안 함(`server/risk/demo.py`, c576c96).
  경로 서버 `demo` 플래그(route·check·sea → `/api/v1/demo/risk/areas`). 배포 후 시연 산사태 영역이 포항 전역 489곳이라 실측처럼 구룡포 bbox로 제한 → 36곳(3d95de1). VM·웹 배포, server 201·route 58 통과.
- 2026-10-06 세션 정리: 루트 CLAUDE.md(시연 모드·demo 엔드포인트·경로 demo 플래그·앱 파일), ai/CLAUDE.md 현재 상태, 이 파일 다음 세션 시작점·이월 항목 갱신.
- 2026-10-07 경로 안내 점검·수정 (B7 후속, 앱 수정은 사용자 허락): ① 앱 "가까운/안전한 길"(`strategy`, 김다인 629dccf)이 사용자 유형을 덮어쓰던 것 →
  `profiles.rules_for`: fastest = 사용자 유형 규칙 그대로, safest = 노약자 경사·계단 규칙 + 걸음 속도는 사용자 유형대로, 응답 profile = 요청 그대로.
  ② `/api/route/check`에 `strategy` 추가 — 재계산해도 같은 종류의 길 (앱 `checkRoute`가 보냄). ③ 앱 위험 구역 이름: 시연 모드면 `/api/route/hazards?demo=true`, 모드 바뀌거나 1분 지나면 다시 받음.
  실측(무위험, 35.98,129.56→35.995,129.545): 성인 가까운 28분·성인 안전 28분(예전 38분)·노약자 가까운 38분(예전 28분). 노약자는 두 버튼 결과가 같다.
  ④ AI 시연 모드 (`guardian_ai/demo.py`, `ChatRequest.demo`, 앱 채팅·음성이 보냄): 실시간 표 6개를 같은 이름의 WITH 절(api /demo/* 데이터)로 가린 SQL —
  tool SQL·규칙 그대로. 경로 tool은 demo:true, 시연 대화는 장기 기억 저장 안 함. compose ai에 `API_URL`.
  ⑤ B11 AI 연결: `tools.request_sea_route`, 위치·경로 agent가 /api/route/sea 먼저 → 바다 위면 항구 기준 대피소 다시 고름, 근거(항구·방향·바닷길),
  `ChatResponse.route.sea`, 앱이 바닷길을 점선으로 (바다 경로는 이동 중 재확인 안 함).
  ⑥ **배포 중인 VM에서 시연 모드 길찾기가 전부 실패하던 것** 발견·수정: 시연 영역 id 음수 → GraphHopper area `flood__3` 거부 → `area_id`가 `flood_n3`.
  실측(로컬 AI + VM 시연 데이터): 시연 침수 질문 = 경보·침수심 230mm·호우경보, 지하주차장 제외 → 구룡포중학교 앞 1087m / 실측 = 정상.
  바다(35.995,129.585) = 북서쪽 삼정항 바닷길 1560m → 삼정2리 버스승강장 앞 225m 3분. 새 결함 #8(침수+대피 질문이 내용 검사에 막혀 대체 답) 기록.
  로컬 api `/demo/risk/areas`는 500 (빈 geometry, server/risk/demo.py `_bbox_of`, A 레인 — 미수정). 테스트 route 61, ai 172 + db 6, app 79 passed·기존 실패 8. 커밋 4ed5ed9, VM deploy.sh + push_web.sh 배포.
  VM 확인: 시연 길찾기 동작(전엔 실패), 재확인 strategy 유지, 시연 구역 이름 31곳, AI 시연 침수 질문 = 경보·230mm·구룡포중학교 앞 2652m.
  남은 문제: ① AI 바다 질문이 VM에서 대체 답 — 위치·경로 agent는 삼정항·대피소를 찾았지만 같이 불린 산사태·침수·강풍 agent가 '대피할 곳 확인 불가'·근거에 없는 1000m를 써서 3회 실패 (결함 #8과 같은 원인, 로컬에선 재시도로 통과).
  ② 시연 모드 길찾기가 1km 거리에 5.9~7.3km·71~87분 우회 + 위험 구역 4곳 통과 — 시연 산사태 경보 26곳이 길을 많이 덮음 (규칙·시나리오 확인 필요).
- 2026-10-07 시연 데이터 정비 (사용자 요청 "기능을 제대로 보여 줄 시연 데이터"): 원인 = 시연 침수(구룡포교 주의·수협 경보)가 시가지 → 동쪽 대피소 해안 도로와
  다리를 막아 1km 대피에 5km 우회. 산림청 산사태위험지도(1·2등급 100m = 53km², 호우경보 때 대피소 9곳 제외)는 **사용자 결정으로 유지**(실측·시연 모두).
  `server/risk/demo.py` `DEMO_DT`(simulate 와 분리): 환승센터 경보 300m · 하나과메기 주의 150m · 나머지 보통. 장면 5개 측정 → `docs/demo-scenario.md`
  (항구 → 구룡포중학교 1187m / 읍사무소 서쪽 침수 주의 회피 2.4→2.9km / 하정리 북쪽 경사 20%→10% / 기본 위치 '지나는 구역' 경고 / 바다 → 삼정항).
  서버 지킴이 테스트 `server/tests/test_demo_scenario.py` (server 207 passed). AI 결함 #8 완화(지시문·근거) + 분류기 '대피소' 목적지 제외 + AI 근거에서 '[시연]' 표시 제거
  → 시연 질문 7/7. 도중 로컬 OrbStack 멈춤(메모리 부족 추정) → `orbctl restart docker` 뒤 스스로 회복, DB 유지. 로컬 DB 시드가 오래돼 demo 영역 500 → `docker compose run --rm loader`로 해결.
  배포(6dc0f1f·214752e): VM 시연 장면 5개 로컬과 같은 값. AI 시연 질문은 지시문만으로 5/7 → `flood.strip_deferrals`(남의 주제 '확인 불가' 문장 제거) 뒤 **VM 7/7, 재시도 0, 답 10~16초**. 웹앱은 바뀐 것 없음(push_web 안 함).
- 2026-10-07 경로 3종(가까운 = 회피 없는 최단 `distance_influence` 5000 / 안전 / 오르막 회피 = 진행 방향 오르막만), 자동차 경로(GraphHopper `car`, turn_costs, 오르막 회피 없음),
  시연 산사태 범위 1등급만(경보는 유지), 경로 화면 지도 = 대시보드 지도, 수위계 위치 표시·범례. AI 기억 → 앱 프로필 반영(덮어쓰기), 첫 설정 강제 제거,
  로그인 강제(익명 없음), VM 계정 서버 기록 전부 삭제(백업 `~/backups/db-before-user-wipe-20261007-1750.dump`), 서비스 워커 끄기·Caddy no-cache, 앱 버전 표시.
- 2026-10-08: 프로필 단일 기준화(사용자 결정) — `tools.get_user_profile` 실제 구현(users·user_profiles·user_places, 로그인 uid), 채팅에서 토큰 uid = user_id 면 서버 프로필이 기준·앱 값은 빈 칸 보충, 장기 기억은 메모·대화 요약만 근거로(프로필 항목은 앱을 거쳐 프로필로). 앱 계정 동기화 보행 능력 버그 수정(무엇을 골라도 limited → 가능 normal·어려움 unable). ai_memory 보강은 사용자가 나중으로 미룸. AI 185 passed.
- 2026-10-08: 판단용 칸 = 화면 값 (사용자 요청 '판단용 칸을 app_state와 일치') — 앱 `AccountSync.profilePatch`: 시각·청각 '필요 없음'이 예로 가던 버그, 보호 동반자·혈액형 추가, 직업은 코드(fisher 등, 직접 입력은 글자), 지운 칸은 기본값으로, 비상 연락처 → `/user/contacts`, 번역 버전(`patchVersion`)이 바뀌면 로그인 때 한 번 다시 보냄. 서버(A) `messages.profile_tags` 어업 판단이 'fisher, other' 도 인식. AI는 직업 코드를 한글로. '자주 방문하는 장소' 글자 칸은 좌표가 없어 서버로 안 보냄(저장 장소는 이미 동기화).
- 2026-10-08: 사용자 결정 '프로필 하나' — AI가 대화에서 들은 정보를 `profile_sync.ProfileWriter`로 사용자 본인 토큰을 써서 서버 프로필(POST /api/v1/user·places)에 바로 반영, 질문마다 서버 프로필을 읽음. `ai_memory` store는 읽기·쓰기 중단(데이터·계정 유지), 기억 API(/api/ai/memory*, /api/ai/me/memory) 삭제. 추출 항목에 시각·청각 추가, 기타 메모·대화 요약 중단. 앱: 'AI가 기억한 정보' 카드·AiMemoryService 삭제 → `AccountSync.pullProfile`(앱 시작·프로필 화면·AI 대화 8·20초 뒤)이 서버 프로필을 화면 값으로, 올릴 때는 바뀐 칸만(`server_profile_base`). AI 189 passed, 앱 account_sync 13 passed.
- 2026-10-08: 시연 모드 대화에서도 사용자 정보를 서버 프로필에 반영 (사용자 요청).
- 2026-10-08: 'AI가 대화에서 수집한 정보' 창 — 서버 `care.profile_updates` 표(`db/init/01m_v0_6_profile_updates.sql`) + API `GET/POST /api/v1/user/profile-updates`, `DELETE …/{id}`(사용자 선택: 서버에 기록). AI `ProfileWriter`가 반영한 것만 기록(칸·값·사용자 말). 앱 프로필 화면 카드(`lib/profile_refresh.dart`). server 212, AI 195, 앱 account_sync 15 passed.
- 2026-10-08: 지원·복구 안내 agent `recovery_support_agent` (`recovery.py`) — 기존 `support_programs` 9건만으로(사용자 결정) 공통 보험·공통 피해 신고·복구·내 직업 지원·복구. 전문 agent 병렬 층 6번째, `tools.get_support_programs`, 분류기 역할·키워드, 혼자 선택되면 행동 권고가 되묻지 않음, 재난 후 '보험·법률 정보 확인 안 됨' 메모 제거, 카드 출처. 앱 '지원 및 복구' 화면(목업)은 그대로. AI 207 passed.
- 2026-10-08: 앱 디자인을 web-prototype으로 (사용자 요청, C 레인 코드) — `app/lib/ui/gk_theme.dart`·`gk_widgets.dart`, Pretendard 줄인 글꼴, 메뉴 4개 + 119 + 머리줄, 대시보드(빨간 재난문자·경보 칩·지도 카드·전체 화면·지표 카드 격자·지원/태풍 카드), AI 대화창(모리·말풍선·추천 질문·마이크), 사용자(내 정보 보기/수정·알림 스위치·내 장소·시연·안전 기능), 대피 확인 창·로그인 화면. 기능·데이터 연결은 그대로.
- 2026-10-08: 로그인 채팅 500 수정(039ddb7) — 서버 프로필 읽기 lambda가 import 안 된 `T`를 써 b087cfa 배포(약 03:40)부터 로그인 사용자 채팅 전부 실패.
  `service.server_profile` + 회귀 테스트. 지원·복구 agent 섞인 질문("태풍 피해 지원")이 강풍 agent의 '지원 정보 확인 불가' 문장으로 검증 실패 → `SUPPORT_TOPICS` 문장 제거(2906f1a), VM 12초·재시도 0.
- 2026-10-08 디자인 작업 중 고친 것: 버튼 textStyle에 글꼴 빠지면 한글 □, 선택 칩 글자(WidgetStateColor), FilledButton 테마 색이 tonal 버튼까지 흰 글자, GkCard 바탕을 Material로(ListTile 물결·디버그 경고).
  앱 테스트 기존 실패 8 → 7. 세션 정리: CLAUDE.md·ai/CLAUDE.md·이 파일 다음 세션 시작점·이월 항목 갱신.
- 2026-10-08 밤: 막혀 있던 외부 데이터 정리 — 재난문자는 IP가 아니라 **VM `.env`에 `SAFETY24_API_KEY`가 없던 것**(로컬 키를 해시 비교로 넣고 api·collector 재생성 → 23:27 수집 성공,
  VM IP 34.64.177.195는 사용자가 safetydata.go.kr에 등록. 로컬 맥 IP는 미등록이라 로컬 수집은 계속 실패). 기상청 단기·중기·태풍·포항 대기질은 이미 수집 성공 중,
  VM 카카오 키도 있음(AI가 '구룡포 일본인가옥거리'를 카카오 검색으로 찾음). 앱: AI 답 생성 중 다른 메뉴로 가도 답 유지(`chatController`·`chatLoading`, e47f177, 웹 배포).
- 2026-10-08 밤 B13: 방문 우선순위 `server/app/priority.py`(사용자 규칙) + 테스트 `server/tests/test_priority.py`(8). 로컬 임시 dev api(api-b13, 8010)로 시연 가구 14곳·수동 대피 상황 → 12곳 대상,
  도움요청+청각장애 1위·지적장애 가구는 2위(장애 아님), 위치 주면 거리순 확인 후 시험 데이터·dev 사용자 삭제. server 220·app 94+7(기존 실패) 통과. VM 배포 전.
- 2026-10-09: 방재단 현황을 일반 대시보드 화면으로(사용자 요청) — 재난문자·특보·재난 지도·날씨 그대로, 지도 위 사람 아이콘(등록 가구: 장애인·어르신·기타, 대피 대상: 사람+우선순위 숫자·상태 색), 지도 앞 대피 상황 머리·필터·범례, 지도 뒤 방문 우선순위/등록 가구 명단. 목업 웹 스크린샷 확인, app 94+7(기존 실패).
- 2026-10-09 00:30: VM 배포(deploy.sh·push_web.sh, ef33e9c) — B13·방재단 현황 화면. 시험 대피 상황(note b13_test)·1회용 초대 코드 발급, VM에서 순위 확인(와상 도움요청 1위·지적장애 도움요청 2위·…·대피 완료 12위).
