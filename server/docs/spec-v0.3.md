# 구룡가디언 — 데이터 구조 · 통신 규약 v0.3 (2026-10-03)

> 목적: 추가 기능 7종(28일판 타임라인)을 A·B·C 가 나눠 만들기 전에 **DB 구조와 API 규약을 먼저 고정**한다.
> 원본: `server/spec/openapi.yaml` (api·ai·route 3개 서비스) · `db/init/01m_v0_3.sql` (스키마 추가분) · 목업 `server/mock/`
> 검사: `server/tests/test_spec.py` — 명세 문법, 목업 ↔ 명세 스키마, FastAPI 경로 ↔ 명세 경로를 대조

## 1. 확정한 것 (2026-10-03)

| 항목 (타임라인 "확정 필요") | 결정 |
|---|---|
| 방재단 계정 부여 방식 | **초대 코드 입력** — 읍사무소가 발급(`POST /internal/invites`), 앱에서 입력(`POST /user/role`) → `users.role` |
| 취약 가구 등록 주체 | **둘 다** — 방재단·생활지원사 대리 등록(`POST /admin/households`, 서면·구두 동의 기록) + 주민 본인 앱 등록(`PUT /user/household`, 앱 동의) |
| 대피 확인 버튼 3종 문구 | **대피 완료**(`evacuated`) / **대피 중**(`evacuating`) / **도움 필요**(`need_help`) |
| 상태 대시보드 범위 | **위험 영역 안 대상 목록 + 전체 요약** (`GET /admin/incidents/{id}` + `GET /admin/overview`) |
| 산사태 판정 | 개편안 확정 — 주의 = 호우주의보 + 위험지도 1등급 100m, 경고 = 호우경보 + 1·2등급 100m (risk_rules 10·11, `09_seed_landslide_riskmap.sql`) |

## 2. v0.2 → v0.3 바뀐 점

**정리 (이미 있던 것을 명세에 맞춤)**
- api 의 목업 `/chat`·`/voice`·`/route`·`/route/check` **삭제** — 실제는 ai `POST /api/chat`, route `POST /api/route`·`/api/route/check` 이고 형식이 달랐다. 명세에 실제 형식을 옮겨 적음 (경로별 `servers`)
- 지도 레이어 속성 보강: stations `stale·age_min·age_label`(자료 신선도), medical `er`(응급실 가용병상), shelters `unsuitable_for·unsuitable_reason`(산사태 때 비추천), landslide_zones `kind(riskmap|designated)·reason`
- `GET /hotlines` 긴급 전화 (DB `public_hotlines`, 실데이터)
- `GET /internal/ingest` 명세에 추가, `/internal/simulate` 시나리오 목록을 실제 구현(heavy_rain_flood · clear)에 맞춤
- 에러 코드 추가: `FORBIDDEN`(403) · `CONFLICT`(409) · `INVALID_INVITE`(400)

**새 기능**
- 역할: `users.role` (resident · responder · caregiver · admin), `POST/DELETE /user/role`, `POST /internal/invites`
- 접근성(C7): `profile.alert_prefs` {tts, strong_vibration, screen_flash, large_text}, 경고 `tts_text`
- 대피 확인(A5·A12): 경고 `response_required` · `incident_id` · `my_status`, `POST /alerts/{id}/response`, 폴링·대시보드에 `evacuation`
- 취약 가구(A13): `PUT/GET/DELETE /user/household`, `/admin/households*`
- 방재단 화면(A12·A14·B13): `/admin/overview`, `/admin/incidents*` (현황·지도·대신 기록·담당 지정·방문 기록·종료)
- 해상 경로(B11): `POST /api/route/sea` **제안**, DB `ports`
- FCM 규약: `FcmPayload.kind` = alert · evacuation · reminder · escalation · incident_closed

## 3. DB (01m_v0_3.sql)

| 위치 | 테이블·컬럼 | 쓰임 |
|---|---|---|
| public | `users.role`, `users.role_granted_at` | 역할 |
| public | `user_profiles.alert_prefs` | 접근성 알림 |
| public | `user_alerts.response_required · incident_id · tts_text` | 대피 확인 경고 |
| public | `ports` (berth, land_point) | B11 항구·접안 지점 |
| **care** | `invite_codes` | 초대 코드 (sha256 만 저장) |
| **care** | `households` | 취약 가구 + 동의 기록 (needs 11종) |
| **care** | `incidents` | 대피 상황 (auto · manual · simulated) |
| **care** | `incident_targets` | 대상별 상태·재알림·이관·담당·B13 점수 |
| **care** | `evacuation_responses` | 상태 변경 이력 |
| **care** | `visit_logs` | 방문 기록 (A14) |

- **care 스키마는 AI 읽기 전용 계정이 못 읽는다** (`07_ai_readonly.sh` 는 public 만 SELECT). B13 우선순위는 A 서버 안에서 계산해 결과만 `incident_targets.priority_*` 에 쓴다.
- 기존 DB 반영: `docker compose run --rm loader` — loader 가 `01m_*` 을 스키마 확인 전에 매번 적용 (재실행 안전). 볼륨 초기화 불필요.
- 산사태 위험지도 시드 이름 변경: `07_seed_landslide_riskmap.sql` → `09_seed_landslide_riskmap.sql` (main 의 `07_ai_readonly.sh`·`08_ai_memory.sh` 와 번호 겹침 방지)

## 4. 대피 확인 흐름

```
판정 엔진: 위험 영역 advisory 이상 생성 (또는 방재단 수동 시작)
  → care.incidents 생성
  → 대상 = 영역 안 등록 가구 + 영역 안 앱 사용자(마지막 위치·등록 장소)
  → 앱 사용자에게 user_alerts(response_required) + FCM kind=evacuation (버튼 3개)
주민: 알림 버튼 / 대시보드 카드 / 음성(B12) → POST /alerts/{id}/response (via = button | dashboard | voice)
  · need_help → 즉시 방재단·담당 생활지원사에게 FCM kind=escalation
  · evacuating → 10분 뒤 FCM kind=reminder
  · 응답 없음 → 2분마다 reminder, 10분 뒤 escalation
방재단: GET /admin/incidents/{id} (10초 폴링) → 우선순위 순 목록
  → 스마트폰 없는 가구는 PATCH .../targets/{id} 로 대신 기록, 방문 후 POST .../visits
  → 종료 POST .../close → FCM kind=incident_closed
```
- 시간 규칙 (2026-10-03 팀 결정): 미응답 2분 간격 재알림 · 10분 뒤 방재단 이관 · 대피 중 10분 뒤 재확인 — 근거 정리 대상 (프로젝트 문서 8번 4절)
- 기본 정렬: 도움 필요 > 미응답 > 대피 중 > 대피 완료, 같은 상태면 사정(needs) 많은 순. B13 점수가 있으면 점수 순

## 5. 작업별 영향

| 작업 | 쓰는 규약 |
|---|---|
| A5 선제 경고 (Day 11–13) | user_alerts(+response_required), `/alerts` 폴링, FCM alert·evacuation |
| A12 대피 응답 (15–16) | incidents·incident_targets·evacuation_responses, `/alerts/{id}/response`, 재알림·이관 |
| A13 취약 가구·동의·권한 (17–18) | households·invite_codes·users.role, `/user/role`, `/user/household`, `/admin/households*`, `require_staff` |
| A14 방문 기록 (19–20) | visit_logs, `/admin/incidents/{id}/targets/{tid}/visits` |
| B11 해상 경로 (15–17) | ports, `/api/route/sea` (제안 — 확정 시 명세 수정) |
| B12 음성 대피 확인 (17–18) | 분류 결과 3종 → 앱이 `/alerts/{id}/response` (via=voice, transcript) |
| B13 우선순위 (19–20) | incident_targets.priority_score·priority_reasons (A 서버 모듈로 실행) |
| C7 접근성 (17–18) | profile.alert_prefs, alert.tts_text, FcmPayload |
| C8 방재단 대시보드·해상 경로 화면 (19–20) | `/admin/*`, `/api/route/sea` |

목업은 지금 바로 쓸 수 있다 (`AUTH_MODE=dev`): 주민 `Bearer dev:<아무거나>`, 방재단 `Bearer dev:responder-1`, 생활지원사 `Bearer dev:caregiver-1`.
`POST /user/role` 은 dev 에서 `DEMO-RESPONDER` · `DEMO-CAREGIVER` · `DEMO-ADMIN` 코드를 받는다.

## 6. 남은 확인 (팀)

1. **좌표 키 이름**: api `lng` ↔ ai·route `lon`. 지금은 그대로 두고 명세에 명시 — 통일할지 B·C 결정
2. **이동수단 철자**: api `public_transit` ↔ ai `public_transport`
3. **ai 인증**: `/api/chat` 에 Firebase 토큰 검증 없음 — B 가 api 의 `auth.verify_token` 방식으로 추가 예정
4. **음성 API**: B5 에서 형식 확정 후 명세에 추가
5. **시간 규칙 근거**: 재알림 2분 간격 · 이관 10분 · 재확인 10분
6. **항구 데이터 출처** (B11)
7. `user_profiles` 의 건강 관련 항목(medical_note·blood_type)도 AI 계정이 읽을 수 있음 — care 로 옮길지 결정

## 7. B·C 검토 체크리스트

**B**
- [ ] `/api/chat`·`/api/route*` 를 명세에 옮겨 적은 내용이 코드와 같은가 (바뀌면 명세도 같이)
- [ ] B12: 음성 분류 결과를 앱에 돌려주고 앱이 `/alerts/{id}/response` 를 부르는 흐름으로 괜찮은가
- [ ] B13: `priority_reasons` 형식 {factor, points, label} 과 A 서버 안 실행 방식
- [ ] B11: `/api/route/sea` 응답(해상 구간 직선·방위 + 육상 경로)과 `ports` 컬럼

**C**
- [ ] 목업만으로 대피 확인 카드·알림 버튼·방재단 현황·가구 등록 화면을 그릴 수 있는가
- [ ] FCM data 형식(kind 5종)과 알림 버튼 3개 처리 (iOS 알림 액션 포함)
- [ ] `alert_prefs` 4개 항목으로 접근성 화면이 충분한가
- [ ] 대피소 `unsuitable_for` 를 산사태 상황에서 어떻게 보여 줄지
