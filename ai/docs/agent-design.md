# 구룡가디언 agent 구조 설계 (B1)

기획서의 Multi-agent 구조를 LangGraph 그래프로 확정한 문서다. 노드·엣지·루프 한도는 `guardian_ai/graph.py`,
상태 스키마는 `guardian_ai/state.py`, DB 조회 tool은 `guardian_ai/tools.py`에 코드로 있다.
노드 본문은 아직 stub이며 B2(골격·관리자) → B3(침수·환각) → B4(재난 확장·행동 권고) → B5(의도·다듬기·음성) 순서로 채운다.

- LLM: OpenAI gpt-6-luna (2026-10-01 Gemini에서 전환, 가성비 기준) / 오케스트레이터: LangGraph
- 테스트: `cd 코드/ai && .venv/bin/python -m pytest` (토폴로지·루프 한도 7건)

## 1. 그래프

```mermaid
flowchart TD
    IN([사용자 질문 · chat 모드]) --> M
    EV([Risk engine 경고 · alert 모드]) --> M
    M[관리자 agent<br/>재난 단계 판정 · agent 선택]
    M -. 선택된 것만 병렬 .-> L[산사태] & R[강수·침수] & W[강풍·태풍] & S[생활안전] & P[위치·경로]
    M -. 선택 없음 .-> A
    L & R & W & S & P --> A[행동 권고 agent<br/>규칙 트리 + 문장화]
    A -. chat .-> I[사용자 의도 검증]
    A --> H[환각 검증]
    I & H --> G{검증 합류}
    G -- 통과 --> PO[답변 다듬기]
    G -- 실패, 재시도 2회 이내 --> M
    G -- 실패, 한도 초과 --> FB([안전 fallback 답변])
    PO --> H2[환각 재검증]
    H2 -- 통과 --> OUT([최종 답변])
    H2 -- 실패, 1회 이내 --> PO
    H2 -- 실패, 한도 초과 --> OUT2([다듬기 전 검증 통과 초안])
```

기획서 구조와 다른 점 (의도적 변경):

| 변경 | 이유 |
| --- | --- |
| 의도 검증과 환각 검증을 **병렬** 실행 후 합류 | 둘 다 같은 초안을 보므로 결과는 같고 지연이 절반 |
| 루프 1 최대 2회, 루프 2 최대 1회 재시도 | 재난 상황에서 무한 루프·과도한 지연 방지 |
| 루프 1 한도 초과 시 fallback 답변 | 검증 못 한 답을 내보내지 않음 |
| 루프 2 한도 초과 시 다듬기 전 초안 반환 | 이미 검증된 내용이므로 형식만 포기 |
| alert 모드 추가 (의도 검증 생략) | 선제 경고(A5)를 같은 그래프로 생성. 사용자 질문이 없어 의도 검증 불필요 |
| 선택된 agent가 없으면 행동 권고로 직행 | 인사·일반 질문의 빠른 경로 |

## 2. 노드

| 노드 | 역할 | 읽는 state | 쓰는 state | tool | LLM |
| --- | --- | --- | --- | --- | --- |
| `manager` | 질문·경고 분석, 재난 단계 판정, 전문 agent 선택. 재시도 시 `manager_feedback` 반영 | question, risk_event, user, current_location, manager_feedback | phase, selected_agents, (specialist_results, checks 초기화) | get_risk_at, get_weather_warnings, get_user_profile | O (선택), 단계 판정은 규칙 |
| `landslide_agent` | 산사태 위험지역과 사용자 위치로 답변 조각 | user, current_location, phase | specialist_results | get_risk_at, get_hazard_zones, get_observations, get_weather_warnings | O |
| `rain_flood_agent` | 강수와 수위를 함께 고려한 호우·침수 답변 | 〃 | specialist_results | get_risk_at, get_observations, get_hazard_zones, get_weather_warnings, get_disaster_messages, get_facilities | O |
| `wind_typhoon_agent` | 강풍·태풍 답변 (선박 보유자는 계류 등 포함) | 〃 | specialist_results | get_risk_at, get_observations, get_weather_warnings, get_disaster_messages | O |
| `life_safety_agent` | 미세먼지·자외선 등급과 행동요령 | current_location | specialist_results | get_life_safety | O |
| `location_route_agent` | 위치 기반 경고, 대피소까지 안전 경로 | user, current_location | specialist_results (route 포함) | get_risk_at, get_facilities, request_route | O |
| `action_advisor` | 판단 트리로 행동 우선순위 결정 → 전문 agent 결과와 합쳐 초안 작성 | phase, specialist_results, user | action_plan, draft | get_action_guides, get_facilities | 문장화만 |
| `intent_check` | 초안이 질문 의도에 답하는지 (chat만) | question, history, draft | checks.intent | - | O |
| `hallucination_check` | 초안의 수치·사실이 evidence와 일치하는지 | draft, specialist_results[].evidence, action_plan | checks.hallucination | - | 숫자는 규칙 대조 + LLM |
| `verify_gate` | 검증 합류, 통과/재시도/fallback 결정 | checks, retry_count | verdict, retry_count, manager_feedback, verified_draft | - | X |
| `polish` | 수치는 표, 긴 글은 요약, 쉬운 문장 | verified_draft, polish_feedback | polished | - | O |
| `final_hallucination_check` | 다듬으며 내용이 바뀌지 않았는지 | polished, verified_draft, evidence | polish_verdict | - | 숫자는 규칙 대조 + LLM |
| `final_check_gate` | 루프 2 재시도 여부 | polish_verdict, polish_retry_count | polish_verdict, polish_retry_count | - | X |
| `finalize` | 최종 답변 확정 | polished 또는 verified_draft | final_answer | - | X |
| `fallback` | 검증 실패 시 최소 안내 (119, 대피소) | - | final_answer, used_fallback | - | X |

환각 검증의 전제: **모든 전문 agent는 답변에 쓴 수치를 `Evidence`로 남긴다.** evidence에 없는 수치가 초안에 있으면 실패.

B3 구현 (2026-10-01):
- `rain_flood_agent` (`flood.py`): ① 코드가 DB에서 위험 판정·수위·강수·특보·재난문자(주의 이상이면 대피소)를 모으고
  ② 코드가 근거(Evidence)를 만들고 ③ LLM(`OpenAIWriter`)은 근거만 보고 2~4문장을 쓴다. 위험 단계는 A의 판정 엔진 값을
  그대로 쓴다. LLM이 실패하면 근거 숫자를 그대로 넣은 템플릿 문장. 위치는 현재 위치 → 집 → 구룡포읍 중심(밝힘).
  DB가 안 되면 "확인할 수 없음"을 밝히고 "안전하다"고 단정하지 않는다. 재시도 때는 `manager_feedback`을 작성기에 넘긴다.
- `hallucination_check` (`verify.py`): ① 숫자 검사(규칙) — 초안의 측정값(mm·cm·m·m/s·%·℃ 등)이 근거와 반올림 오차
  안에서 맞는지, 단위 변환 허용 ② 내용 검사(LLM, `OpenAIFactChecker`, 추론 medium) — 특보·위험 단계·근거 없는 사실·
  관측소 바꿔치기. ①에서 걸리면 ②는 부르지 않는다. ②가 장애면 ①의 결과로 판단. 모델은 `OPENAI_VERIFY_MODEL`로 따로 올릴 수 있다.
- 검증 결과 (gpt-6-luna, 2회 반복): 틀린 답 10/10 걸러짐, 맞는 답 3/3 통과 (`tests/test_verify_live.py`).
- 관측값은 시연용 모의값을 6시간 동안 실측보다 우선한다 (A 판정 엔진과 같은 규칙 — 판정과 근거 수치가 어긋나지 않게).

관리자 agent 동작 (B2 구현):
- chat 모드: LLM(OpenAI)이 질문·최근 대화·사용자 프로필(재시도면 실패 사유 포함)을 보고 전문 agent를 고른다 (`llm.py` `OpenAIClassifier`).
  LLM이 실패하거나 10초 안에 답하지 않으면 **키워드 분류로 대체**한다. 재난 중 AI 장애로 답이 끊기지 않게 하기 위함.
- alert 모드: LLM 없이 규칙으로 고른다. 산사태→산사태, 호우·침수→강수·침수, 강풍·태풍→강풍·태풍, 미세먼지·자외선→생활안전.
  위치·경로 agent는 경보(WARNING) 단계이면서 대피가 필요한 재난(산사태·호우·침수·강풍·태풍)일 때만 붙는다.
- 새 질문이 들어오면 이전 질문의 재시도 횟수·실패 사유를 초기화한다. 검증 실패로 되돌아온 경우(`verdict == "retry"`)만 이어 간다.
- 재난 단계(phase) 판정은 아직 stub(항상 '재난 중'). B4에서 특보·위험 판정 규칙으로 구현.

## 3. 상태 (`GuardianState`)

| 그룹 | 필드 | 비고 |
| --- | --- | --- |
| 입력 | mode, user, current_location, question, risk_event, history, user_memory | mode = `chat` 또는 `alert`, user_memory = 사용자 기억 문장 (아래 기억 절) |
| 관리자 | phase, selected_agents, manager_feedback | |
| 전문 → 권고 | specialist_results, action_plan, draft | specialist_results는 병렬 누적 reducer, 재시도 시 RESET |
| 루프 1 | checks, retry_count, verdict | checks는 병렬 병합 reducer |
| 루프 2 | verified_draft, polished, polish_feedback, polish_retry_count, polish_verdict | |
| 출력 | final_answer, used_fallback | |

도메인 모델: `UserProfile`, `Location`, `RiskEvent`, `Evidence`, `SpecialistResult`, `ActionPlan`, `CheckResult`, `ActionGuide`.
enum: `DisasterType`(9종, DB hazard_type과 같음), `Phase`(전·중·후·평시), `RiskLevel`(DB와 같은 5단계 normal·watch·advisory·warning·critical), `Specialist`, `Mobility`.

## 4. 행동 권고 판단 트리 (규칙, B4에서 구현)

```mermaid
flowchart TD
    P{재난 단계} --> B[재난 전]
    P --> D[재난 중]
    P --> F[재난 후]
    B --> B1[대비 행동요령 + 예보] --> B2[부족한 사용자 정보 질문] --> B3[체크리스트]
    D --> D0{사용자 위치 위험도}
    D0 -- 안전 --> D1[행동요령 + 실시간 정보]
    D0 -- 위험 지역 --> D2{이동 가능?}
    D2 -- 불가 --> D3[구조 요청 · 119 연결]
    D2 -- 가능 --> D4[대피소 안전 경로]
    F --> F0{거주지 피해?}
    F0 -- 없음 --> F1[실시간 현황<br/>위험지역 · 통제도로]
    F0 -- 있음 --> F2[임시 거주지 · 주의사항<br/>보험·법률 안내]
```

재난 단계 판정 (관리자, 규칙):

| 단계 | 조건 |
| --- | --- |
| 전 | 예비특보(`status=planned`) 있음, 또는 예보상 기준 도달 예상 |
| 중 | 특보 발효(`active`) 또는 Risk engine이 사용자 위치 반경 내 `advisory` 이상 판정 |
| 후 | 특보 해제(`lifted`) 후 **N시간 이내** (N은 열린 질문) |
| 평시 | 위 조건 없음 |

"이동 가능"은 `UserProfile`(보행 장애, 휠체어, 동반자)과 경로 존재 여부로 판단. 정보가 없으면 질문한다.
행동 권고 agent는 `get_action_guides`로 가져온 원문만 인용하고, 인용한 id를 `ActionPlan.guide_ids`에 남긴다.

## 5. DB 조회 tool 명세 — 직접 조회 (B3, 2026-10-01 결정)

**조회 방식**: AI 프로세스가 PostgreSQL을 **읽기 전용 계정으로 직접 조회**한다 (기획서 "데이터베이스와 AI agent를 연결").
A의 FastAPI는 앱·웹이 부르는 창구로 남고, AI는 거치지 않는다. 쓰기는 A의 수집기·판정 엔진만 한다.
- 계정: `db/init/07_ai_readonly.sh`가 만든 `AI_DB_USER`(기본 guardian_ai) — public 스키마 SELECT만, 계정 기본값과
  접속 옵션 두 겹으로 읽기 전용 트랜잭션, 조회 3초 제한. 이미 만든 DB에는 스크립트를 한 번 직접 실행한다.
- 코드: `guardian_ai/db.py`(커넥션 풀, 첫 조회 때 연결), `guardian_ai/tools.py`(SQL과 결과 변환).
- A와의 약속: AI가 아래 표·뷰를 읽는다. **컬럼 이름이나 의미를 바꿀 때는 B에게 알린다.**

공통: 반환은 dict `{"available": True, ..., "source": <테이블>}`, 실패하면 예외 대신 `{"available": False, "reason"}`.
좌표 WGS84, 시간 ISO 8601(+09:00), 거리 m 정수. 위험 단계는 DB와 같은 5단계 `normal < watch < advisory < warning < critical`.

| tool | 인자 | 반환 핵심 키 (`items[]`) | 읽는 표 |
| --- | --- | --- | --- |
| `get_risk_at` | lat, lon, radius_m=500 | max_level, data_stale(판정 30분 이상 멈춤), items: hazard, level, label, reason(엔진 근거 문장), metric·value·unit, distance_m, observed_at, simulated | risk_assessments, ingest_runs |
| `get_observations` | kind(water_level·rain·wind·uv·air), lat, lon | station, metric, value, unit, level_label(포항 DT 등급), observed_at, distance_m, stale(2시간) | v_latest_observations |
| `get_weather_warnings` | lifted_hours=24 | hazard, level, region, headline, status(planned·active·lifted), issued_at, lifted_at | weather_warnings |
| `get_disaster_messages` | hours=6 | sent_at, sender, category, hazard, alert_class, text | disaster_messages (재난안전24 키 받기 전 비어 있음) |
| `get_hazard_zones` | lat, lon, radius_m, kind=landslide | zone_id, name, grade, contains_point, distance_m | hazard_zones (산사태 488곳, 침수 구역은 A가 삭제) |
| `get_facilities` | kind(shelter·medical·manhole), lat, lon, limit, shelter_type | facility_id, name, lat, lon, distance_m + 종류별(대피소 종류·수용인원, 응급실 직통) | shelters, medical_facilities, manholes |
| `get_life_safety` | lat, lon | uv·pm10·pm25 각 value·grade (미세먼지는 수집 권한 전까지 None) | v_latest_observations |
| `get_action_guides` | disaster, phase, level, targets | `ActionGuide`와 같은 키: id, min_level, targets, priority, title, content, voice_text, source_name | action_guides (51건) |
| `get_user_profile` | user_id | UserProfile 키 | **목업** — 지금은 앱이 요청에 프로필을 실어 보낸다 |
| `get_safe_shelters` | lat, lon, limit=8 | name, lat, lon, distance_m, is_indoor, underground, safe, excluded_reason(위험 영역 안·침수 중 지하) | shelters, risk_assessments (앱과 같은 규칙) |
| `find_place` | query, user | available, name, lat, lon, kind(home·work·place·shelter·medical), source(user·db·kakao), address, out_of_area | profile 등록 장소, shelters·medical_facilities, 카카오 로컬 키워드 검색 |
| `hazards_at` | lat, lon | labels(지점이 들어 있는 침수·산사태 영역, 주의 이상) | risk_assessments |
| `request_route` | origin, destination, profile(adult·elderly) | available, distance_m, duration_s, ascend_m, descend_m, max_slope_pct, avoided, still_inside, hazards_ok, geometry | route 서비스 HTTP (B6·B7). 회피: 판정 엔진의 침수·산사태 영역(주의 이상), 맨홀 없음 |

데이터에서 알게 된 것 (2026-10-01): 구룡포 대피소 19곳은 지진해일(17)·민방위(2)만 지정, **침수 지정 대피소 없음** →
침수 안내는 `shelter_type=None`으로 가까운 대피소를 쓴다. 의료시설 5곳은 포항 시내 응급실(구룡포에서 약 20km).
조위·파고는 아직 수집하지 않는다.

## 6. 행동요령 데이터 형식 (`ActionGuide`)

A7이 `action_guides` 표에 적재한 형식을 그대로 쓴다 (2026-10-01, 이전 문자열 id·audience 안을 대체).

```json
{"id": 1, "disaster": "heavy_rain", "phase": "during", "min_level": "advisory", "targets": ["all"], "priority": 10,
 "title": "호우가 시작되면", "content": "(원문 그대로)", "voice_text": "(음성용 짧은 문장)",
 "source_name": "포항시 재난안전 홈페이지", "source_url": null}
```

- `phase`: before, during, after / `min_level`: 이 단계 이상일 때만 보여 준다
- `targets`: all, resident, tourist, fisher, vessel_owner, coastal, farmer, driver (`all`은 항상 포함해 조회)
- `priority`: 낮을수록 먼저. 행동 권고 agent는 이 문장만 인용한다

## 6-1. 기억 (2026-10-02, `memory.py`)

| | 단기 기억 (대화 안) | 장기 기억 (사용자별, 대화를 넘어) |
| --- | --- | --- |
| LangGraph 기능 | Checkpointer — `InMemorySaver` (서버 메모리) | Store — `PostgresStore` (DB) |
| 구분 | thread_id = conversation_id | 이름공간 `("users", user_id, "facts" / "episodes")` |
| 내용 | 그래프 상태 전체 (대화 기록·근거·검증 결과) | 사용자가 자기에 대해 직접 말한 사실(보행 불편·나이·동반자·이동수단·직업·자주 가는 곳·기타) + 대화별 한 문장 요약 |
| 저장 | 그래프 실행 때 자동 | 응답 뒤 백그라운드에서 `OpenAIMemoryExtractor`가 추출 → `store.put` (이어지는 대화는 요약을 넓힘) |
| 수명 | 마지막 문답 후 1시간(`CONVERSATION_TTL_MIN`) 또는 서버 재시작까지 — 지나면 지우고 새 대화로 시작 | 사용자가 지울 때까지 |
| 읽기 | 같은 conversation_id로 요청하면 자동 | 대화마다 `ChatService`가 불러와 ① 앱이 안 보낸 프로필 칸 채움(→ 노약자 경로 등) ② 관리자 분류 프롬프트에 "기억하는 것" ③ 침수 agent 근거에 `user_memory`(검증 오탐 방지) |

- 단기 기억을 DB가 아닌 메모리에 두는 이유(사용자 결정 2026-10-02): 질문 1개당 체크포인트가 약 12개 쌓이는데 다음 질문에 쓰는 건
  최근 문답뿐이고, 위치·건강 정보가 대화 상태째로 영구 저장되지 않게. 남길 것(사용자 사실·대화 요약)은 장기 기억이 들고 있다.
- 장기 기억 저장 위치: `ai_memory` 스키마, 전용 계정 `AI_MEM_DB_USER` (`db/init/08_ai_memory.sh`) — public(재난 데이터) 권한 없음.
  표는 `setup()`이 만든다. DB에 못 닿으면 메모리 저장으로 대체(재시작 시 소실).
- 원칙: **재난 정보는 기억하지 않는다**(항상 DB 최신값), 추측은 저장하지 않는다, 앱이 보낸 프로필이 기억보다 우선.
- 대화 주인: 진행 중인 대화의 주인을 서버 메모리에 기록, 남의 conversation_id·만료된 id·모르는 id(재시작 전)는 새 대화로 시작.
- 동의: `ChatRequest.remember`(기본 켜짐, 사용자 결정) — 끄면 불러오기·저장 모두 안 함. 보기·지우기 `GET/DELETE /api/ai/memory/{user_id}`
  (인증 전이라 외부 비공개, B10 Caddy에서 막는다). 서버 종료 때 백그라운드 저장이 끝날 때까지 기다린다.

## 7. 열린 질문

1. 재난 '후' 판정 기간 N시간 (예: 특보 해제 후 24시간)?
2. 맨홀 위치 데이터를 포항 디지털 트윈이 제공하는가? (A7과 동일 질문)
3. ~~AI의 DB 직접 조회(읽기 전용) vs FastAPI 경유~~ → 직접 조회로 결정 (2026-10-01, 5절)
4. 한 질문당 LLM 호출이 최소 5회. 음성 대화에서 지연이 크면 alert 모드처럼 의도 검증 생략, 또는 단순 질문은 다듬기 생략 검토 (B5에서 측정 후 결정)
5. ~~대화 중 알게 된 사용자 정보 저장 주체~~ → AI가 자기 기억 저장소(`ai_memory`)에 저장 (2026-10-02, 6-1절). A의 `users`·`user_profiles`와 동기화할지는 남은 질문

## 8. 채팅 API (B2, 초안)

AI는 별도 컨테이너(`ai`, 포트 8001)로 운영한다. 배포 시 Caddy가 `/api/chat`을 ai로, 나머지 `/api`는 A의 서버로 넘긴다.

`POST /api/chat`

```json
// 요청
{
  "user_id": "firebase-uid",
  "question": "비 오는데 지금 걸어서 집에 가도 되나요?",
  "profile": { "user_id": "firebase-uid", "user_type": "resident", "age": 72, "walking_impaired": true,
               "home": { "lat": 35.9935, "lon": 129.5498, "label": "집" },
               "frequent_places": [{ "lat": 35.9879, "lon": 129.5548, "label": "직장" }] },
  "current_location": { "lat": 35.99, "lon": 129.556 },
  "conversation_id": null
}
// 응답
{
  "conversation_id": "d85990ff…",
  "answer": "…",
  "selected_agents": ["rain_flood_agent", "location_route_agent"],
  "phase": "during",
  "used_fallback": false,
  "route": {                       // 위치·경로 agent가 경로를 안내했을 때만 (안전 안내로 끝난 답이면 null)
    "destination": { "name": "충혼탑 앞", "lat": 35.99144, "lon": 129.56073, "kind": "shelter" },  // kind: shelter·medical·home·work·place
    "profile": "elderly", "distance_m": 1024, "duration_s": 984,
    "avoided": ["flood-67"], "still_inside": [], "hazards_ok": true,
    "geometry": "…"                // 경로 서버와 같은 인코딩 polyline → 앱 "지도에서 경로 보기"
  }
}
```

- 목적지: 관리자 분류기가 질문에서 `destination`("구룡포항", "집")과 `mobility_limited`(이번 질문에서 보행 불편을 말함)를 같은 호출로 뽑는다
  (LLM 실패 시 규칙: `graph.keyword_destination`·`keyword_mobility_limited`). 목적지 찾기 `find_place`: 등록 장소 → DB 시설 이름 →
  카카오 장소 검색(`KAKAO_REST_KEY`, 기준점 구룡포읍 중심 고정). 목적지가 발효 중인 침수·산사태 영역 안이면 경로는 가장 가까운
  안전한 대피소로 낸다(위험한 곳으로 길을 그리지 않음). 못 찾으면 그렇다고 밝히고 가장 가까운 안전한 대피소.

- `conversation_id`가 없으면 새 대화를 시작하고 응답에 id를 돌려준다. 같은 id를 보내면 이전 대화를 기억한다("거기는요?" 해석).
- `profile`·`current_location`은 선택. 사용자 정보 저장 주체는 열린 질문 5번.
- 대화 기억은 지금 메모리에 있어 ai 컨테이너를 재시작하면 사라진다. 필요하면 PostgreSQL 저장으로 바꾼다.
- 목업의 카드형 답변(판정 제목·수치 칩·할 일·출처·버튼)은 B5 다듬기에서 응답에 필드를 추가한다. C와 형식 합의 필요.
- `GET /api/ai/health` → `{"status":"ok"}`
