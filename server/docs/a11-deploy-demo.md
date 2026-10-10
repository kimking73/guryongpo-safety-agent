# A11 배포·시연 준비 — A 레인 (서버·DB·수집)

> 2026-10-04 작성, 최종 배포(Day 27) 전에 갱신. 배포 서버 자체(VM·Caddy·`deploy/deploy.sh`·웹 올리기)는
> 루트 `README.md` "배포 서버 (B10)" 가 원본이다 — 이 문서는 그 위에서 **A 레인이 챙길 것**과 **시연 순서**만 다룬다.
> 키·비밀번호 값은 여기에 적지 않는다 (팀 비공개 채널).

## 1. 배포 전 체크리스트 (VM `.env`·외부 등록)

| 항목 | 없으면 | 확인 |
|---|---|---|
| `API_AUTH_MODE=firebase` | dev 토큰(`Bearer dev:…`)으로 누구나 접근 — **배포 금지** | `.env` |
| `API_INTERNAL_TOKEN` | `/internal/*`(시연 시나리오·초대 코드)이 막힘 | `.env` (밖에서는 Caddy 가 404, 컨테이너 안에서만 사용) |
| `FIREBASE_CREDENTIALS` + `secrets/firebase-admin.json` (서비스 계정 **JSON 전체**) | 앱 로그인 토큰 검증 실패(401), 푸시(경고·재알림·이관) 안 감 — 폴링으로만 전달 | 컨테이너에서 `python -c "from app import auth; print(auth.init_firebase())"` → True |
| `POHANG_TWIN_API_KEY`, `KMA_API_KEY` | 수위·기상 수집 실패 → 판정 불가 | `/api/health` 의 `ingest.pohang_dt`·`ingest.kma` |
| `SAFETY24_API_KEY` + **VM 고정 IP(34.64.177.195)를 재난안전데이터공유플랫폼에 등록** | 재난문자 수집 down (`/api/health` degraded), 재난문자 대피 지시 경고 안 됨 | `ingest.safety24` = ok |
| `DATA_GO_KR_API_KEY` | 응급실 가용병상 없음 (의료시설 레이어 `er` 비어 있음) | `ingest.nmc` |
| `KAKAO_REST_KEY` | **주소만** 보낸 장소 등록 503 (좌표로 등록은 됨) | 앱에서 주소로 집 등록 |

- DB 스키마 추가분은 `deploy.sh` 의 loader 단계가 자동 적용: `01m_v0_3`(대피·가구), `01m_v0_4_households`(동의서 버전·건강 정보 care 이동), `01m_v0_5_visits`(앱 사용자 방문 기록). 출력에 "스키마 추가분: …" 3줄
- 수집기는 판정·경고까지 돌린다: 선제 경고 10분(`risk.alerts`), 재알림·이관 1분(`risk.evac_followup`)

## 2. 배포 후 확인 (A 레인)

VM 에서 (`cd ~/guryongpo-safety-agent`, `C="docker compose -f docker-compose.yml"`):

```bash
curl -s https://34-64-177-195.nip.io/api/health                        # status ok, ingest.* ok
$C exec -T api python - status  < server/tools/demo.py                  # 같은 내용 (컨테이너 안)
$C exec -T api python - prepare < server/tools/demo.py                  # 시연 가구 5곳
$C exec -T api python - flood   < server/tools/demo.py                  # 모의 호우·침수 → 경고
```

**실제 기기 푸시 확인** (A5·A12 이월 항목 — Firebase JSON 이 있어야 함):
1. 앱(휴대폰)에서 로그인 → 알림 허용 (`/device-token` 등록) → 집을 구룡포환승센터 앞으로 등록
2. `flood` 실행 → 휴대폰에 **대피 확인 푸시**(버튼 3개)가 오는지
3. 응답하지 않고 2분 기다림 → **재알림 푸시**
4. 방재단 계정(초대 코드 `POST /internal/invites` → 앱에서 입력) 휴대폰에서 주민이 '도움 필요' → **이관 푸시**
5. `reset` → **대피 상황 종료 푸시**

```bash
$C exec -T api python - reset < server/tools/demo.py                    # 모의값·시연 가구 정리
```

## 3. 시연 순서 (`server/tools/demo.py`)

| 명령 | 하는 일 |
|---|---|
| `status` | 서버·수집 상태 |
| `prepare` | 시연용 가상 취약 가구 5곳 ("[시연] …", 실제 개인정보 없음 — 침수 영역 2·산사태 취약지역 100m 안 1) |
| `flood` | 모의 호우·침수 → 판정 → 영역 안 사용자에게 대피 확인 경고, 시연 가구는 방재단 대상으로 |
| `walkthrough [--step]` | 주민 '도움 필요' → 방재단 대피 현황(1순위·이관) → 방문 '함께 대피' → 집계·주민 카드 반영. **dev 모드 서버(로컬)만** |
| `reset` | 모의값 삭제(대피 상황 종료) · 시연 가구 삭제 · 시연 사용자 삭제 |

- 배포 서버(firebase 모드)에서는 `prepare`·`flood`·`reset` 만 스크립트로, 주민·방재단 화면은 **실제 앱 두 대**(주민 폰 + 방재단 폰)로 진행
- 발표 중 순서: `reset` → `prepare` → (주민 앱 집 등록 확인) → `flood` → 주민 폰 '도움 필요' → 방재단 폰 대피 현황·방문 기록 → `reset`
- 모의값은 6시간 뒤 자동으로 실측에 밀린다. 시연 직전에 `flood` 를 다시 실행하면 된다

## 4. 시연 실패 대비 — 노트북 하나로 로컬 실행

배포 서버·네트워크가 안 될 때. 맥(OrbStack)에서:

```bash
docker compose up -d --build                     # .env: API_AUTH_MODE=dev
docker compose run --rm loader                   # 스키마·시드
docker compose exec -T api python - status < server/tools/demo.py              # 컨테이너 안에서 실행 (토큰 환경 변수가 거기 있음)
docker compose exec -T api python - prepare < server/tools/demo.py
docker compose exec -T api python - flood < server/tools/demo.py
docker compose exec -T api python - walkthrough --step < server/tools/demo.py   # 단계마다 Enter
cd app && flutter run -d chrome --dart-define=APP_MODE=remote                   # 앱 화면도 로컬 서버로
```
- 로컬은 재난문자 수집이 down 이다 (등록 IP 아님) — 시연과 무관
- 외부 API 없이도: `COLLECTOR_FETCH_MODE=replay` 면 저장된 원문(`server/mock/external`)으로 수집

## 5. 시연 후 VM 정리 (B 레인과 함께 — VM·고정 IP 는 김종연 계정)

1. DB 백업: `deploy.sh` 와 같은 방식 — `$C exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > ~/backups/final.dump` 후 맥으로 복사
2. VM 중지: `gcloud compute instances stop guryongpo-safety-agent --zone asia-northeast3-b`
3. **고정 IP 는 VM 을 꺼도 요금이 나간다** → 더 쓰지 않으면 `gcloud compute addresses delete guryongpo-ip --region asia-northeast3`
4. 키 정리: 재난안전데이터공유플랫폼 등록 IP 삭제, 시연용 초대 코드 회수, 필요 없으면 Firebase 서비스 계정 키 폐기
5. 시연용 가상 데이터는 `reset` 으로 이미 삭제 — 실제 사용자 데이터가 있으면 백업 후 볼륨 삭제

## 6. 남은 것 (Day 27)

- [ ] 최종 코드로 `deploy.sh` → 1·2절 확인 → 이 문서 갱신
- [ ] 완료 기준: **다른 팀원이 이 문서 + 루트 README 대로 재배포 성공**
