# 구룡가디언 (구룡포 재난 지킴이)

2026 디지털 트윈 구룡포 AI 해커톤 — 팀 구룡포는구룡.
재난 정보를 한 대시보드에 모으고, 사용자 맞춤형 AI agent가 선제 경고·안전 경로·행동 요령을 안내하는 서비스.

## 저장소 구조

| 폴더 | 내용 | 담당 |
| --- | --- | --- |
| `server/` | FastAPI 서버 (`/api/...`) | A |
| `ai/` | LangGraph multi-agent (`ai/CLAUDE.md`, `ai/docs/agent-design.md`) | B |
| `app/` | Flutter 앱·웹 | C |
| `db/init/` | DB 최초 생성 시 실행되는 SQL (PostGIS 확장) | A |
| `secrets/` | 서비스 계정 키 등 비밀 파일 (커밋 안 됨) | - |

## 처음 설정

### 1. 도구 설치

**Mac**
1. [OrbStack](https://orbstack.dev) 설치 (`brew install --cask orbstack`) → 앱을 한 번 실행해 설정 완료
   - Docker Desktop을 이미 쓰고 있다면 그대로 써도 된다.
2. git: `git --version`으로 확인 (없으면 `xcode-select --install`)

**Windows**
1. WSL2 설치: 관리자 PowerShell에서 `wsl --install` → 재부팅 → Ubuntu 사용자 만들기
2. [Docker Desktop](https://www.docker.com/products/docker-desktop/) 설치 → Settings → Resources → WSL Integration에서 Ubuntu 켜기
3. **이후 모든 명령은 Ubuntu(WSL) 터미널에서 실행한다.**
4. **저장소는 WSL 안(`~/`)에 clone한다.** `C:\Users\...`(`/mnt/c/...`)에 두면 매우 느리고 파일 감시(자동 재시작)가 동작하지 않는다.

### 2. 저장소 받기

```bash
git clone https://github.com/kimking73/guryongpo-safety-agent.git
cd guryongpo-safety-agent
```

### 3. 환경 변수

```bash
cp .env.example .env
```
- 로컬 DB는 기본값 그대로 동작한다.
- API 키와 `secrets/firebase-admin.json`은 **팀 비공개 채널**로 받아서 넣는다.

### 4. 실행

```bash
docker compose up -d --build
```

확인:
```bash
docker compose ps                        # db, api, ai 모두 (healthy)
curl localhost:8000/api/health           # {"status":"ok","db":"ok"}
curl localhost:8001/api/ai/health        # {"status":"ok"}
curl -X POST localhost:8001/api/chat -H 'Content-Type: application/json' \
     -d '{"user_id":"me","question":"비 오는데 걸어서 가도 돼요?"}'
```
- API 문서: http://localhost:8000/docs (서버), http://localhost:8001/docs (AI)
- AI가 Gemini를 쓰려면 `.env`의 `GEMINI_API_KEY`가 필요하다. 없으면 키워드 분류로 동작한다.
- DB 접속: `localhost:5433`, 사용자·비밀번호·DB 이름은 `.env`의 `DB_*`
  (5432는 로컬에 설치된 PostgreSQL과 겹칠 수 있어 5433을 쓴다)

## 자주 쓰는 명령

```bash
docker compose up -d --build     # 시작 (코드 의존성이 바뀌면 --build)
docker compose logs -f api       # API 로그 보기
docker compose down              # 중지 (DB 데이터는 유지)
docker compose down -v           # 중지 + DB 데이터 삭제 (db/init SQL을 다시 실행하고 싶을 때)
docker compose exec db psql -U guardian -d guardian   # DB 셸
```
- `server/app/`, `ai/guardian_ai/` 코드를 고치면 해당 서버가 자동으로 재시작된다 (재빌드 불필요).
- 배포 시 Caddy가 `/api/chat`은 ai(8001)로, 나머지 `/api`는 서버(8000)로 넘긴다 (B10).

## 환경 변수 규칙

- `.env`는 절대 커밋하지 않는다. `.env.example`은 항상 모든 키를 담는다.
- 새 키를 추가하면 **같은 커밋에서** `.env.example`에도 추가한다 (값은 비우거나 로컬 기본값).
- 이름은 대문자 스네이크 + 영역 접두사: `DB_`, `API_`, `GCP_`, `FIREBASE_`, `GEMINI_`, `KMA_`, `POHANG_TWIN_`, `SAFETY24_`
- 파일로 된 비밀은 `secrets/`에 두고 `.env`에는 경로만 쓴다.
- 주석은 반드시 별도 줄에 쓴다. `KEY=  # 설명`처럼 값 뒤에 붙이면 docker가 주석까지 값으로 읽는다.
- 실제 키 값은 팀 비공개 채널로만 공유한다. 저장소·이슈·PR·공개 채팅에 붙이지 않는다.

## 서비스 추가 규칙

- 새 서비스(risk, collector, graphhopper, loader)는 담당 작업에서 `docker-compose.yml`에 추가한다.
- 모든 서비스에 `restart: unless-stopped`와 `healthcheck`를 둔다.
- 로컬에서만 필요한 설정(포트 노출, 코드 마운트)은 `docker-compose.override.yml`에 둔다.
  서버에서는 `docker compose -f docker-compose.yml up -d`로 override 없이 실행한다.

## 클라우드

| 항목 | 값 |
| --- | --- |
| GCP 프로젝트 | `guryong-guardian-0924` (리전 `asia-northeast3` 서울) |
| Firebase | 같은 프로젝트, 익명 인증·FCM 활성화 |
| 예산 알림 | 0원 기준 (크레딧 차감 후 실제 청구가 생기면 메일) |

- GCP 콘솔: https://console.cloud.google.com/home/dashboard?project=guryong-guardian-0924
- Firebase 콘솔: https://console.firebase.google.com/project/guryong-guardian-0924/overview
