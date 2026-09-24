# CLAUDE.md

Repository root for 구룡가디언. Work inside `ai/` is governed by `ai/CLAUDE.md` (read it when touching AI code).

**Every session:** follow "Session start" / "Session end" in `ai/CLAUDE.md`. Where we left off, the next task,
and carry-over items are in `ai/.claude/docs/timeline.md` ("다음 세션 시작점", "이월 항목").

## Project overview
구룡가디언 (구룡포 재난 지킴이) — a disaster-response service for 구룡포 (Pohang) built for the
2026 디지털 트윈 구룡포 AI 해커톤 (team 구룡포는구룡, 3 devs, 21-day plan). It merges scattered disaster data
(포항 디지털 트윈, 기상청, 재난안전24, 공공데이터포털, 생활안전지도) into one map dashboard, and a user-personalized
LangGraph AI agent answers questions, sends proactive warnings, and guides safe evacuation routes
(landslide, heavy rain/flood, strong wind/typhoon, fine dust/UV).

Lanes: **A** server/DB/data collection/risk engine (`server/`, `db/`) · **B** AI + routing + infra (`ai/`, compose,
GCP) · **C** Flutter app/web (`app/`). The user of this repo works lane B.

## Tech stack
- Python 3.12 containers (local venvs ≥3.11), FastAPI + uvicorn for every HTTP service
- PostgreSQL 17 + PostGIS 3.5 (`imresamu/postgis`, multi-arch — official image lacks arm64)
- AI: LangGraph ≥1.0, Pydantic v2, google-genai (Gemini); voice planned: Google Cloud STT/TTS
- Routing (planned, B6): GraphHopper + OSM + 국토지리정보원 DEM
- Client (planned, C2): Flutter; Firebase anonymous auth + FCM
- Infra: Docker Compose (OrbStack on Mac, Docker Desktop + WSL2 on Windows); GCP project
  `guryong-guardian-0924` (asia-northeast3), deploy VM + Caddy planned in B10

## Key directories
| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Services shared by local and server: `db` (:15), `api` (:32), `ai` (:50); project name fixed (:12) |
| `docker-compose.override.yml` | Local-only: DB host port 5433, code mounts + `--reload` |
| `server/` | FastAPI server (lane A). Only `/api/health` exists (server/app/main.py:15) |
| `ai/` | LangGraph multi-agent + `POST /api/chat` (ai/guardian_ai/api.py:34). See `ai/CLAUDE.md` |
| `app/` | Flutter project placeholder (README only until C2) |
| `db/init/` | SQL run once on an empty DB volume (PostGIS extension) |
| `secrets/` | Credential files, gitignored except `.gitkeep` (e.g. `firebase-admin.json`) |
| `.env.example` | Every env key with local defaults; rules in its header (.env.example:2-8) |
| `README.md` | Team-facing setup (Mac/Windows), common commands, env and service rules |

## Commands
Run from this directory (`코드/`).
```bash
cp .env.example .env                         # first time; fill keys from the team's private channel
docker compose up -d --build                 # start db, api, ai (override auto-merged)
docker compose ps                            # all services should be (healthy)
curl localhost:8000/api/health               # {"status":"ok","db":"ok"}
curl localhost:8001/api/ai/health            # {"status":"ok"}
docker compose logs -f ai | grep 라우팅       # per-question AI routing result
docker compose up -d --force-recreate ai     # after editing .env (env is read at container start)
docker compose down [-v]                     # stop (-v also wipes DB data, re-runs db/init)
docker compose -f docker-compose.yml up -d   # server mode: no override, DB not exposed
cd ai && .venv/bin/python -m pytest -q       # AI tests (offline); `-m live` calls real Gemini
```

## Working rules
- Never print or paste `.env` values or files under `secrets/` into output; compare secrets by hash if needed.
- `git push` to the public-history repo `kimking73/guryongpo-safety-agent` may be blocked for Claude; when it is,
  ask the user to run `! git push`. Pull before starting work — teammates also push to `main`.
- `.env` changes need a container recreate, not just a code reload.
- New env key → add to `.env.example` in the same commit, comment on its own line (never after the value).
- New service → add to `docker-compose.yml` with `restart: unless-stopped` + `healthcheck`; local-only bits go
  in the override file.
- Don't edit `server/` or `app/` beyond scaffolding without the user's say-so — they belong to lanes A and C.
- User-facing text, docs, and code comments are Korean; the user prefers explanations in Korean, non-technical
  when they ask for summaries.

## Additional documentation
Check these when relevant:
- `.claude/docs/architectural_patterns.md` — cross-service patterns: config, compose split, container shape,
  HTTP/health conventions, graceful degradation, injectable dependencies, test layering
- `ai/CLAUDE.md` — AI lane status, commands, rules, session start/end routine
- `ai/.claude/docs/timeline.md` — 21-day plan, B-lane tasks and status, work log (live copy is a claude.ai artifact)
- `ai/.claude/docs/architectural_patterns.md` — LangGraph node/reducer/routing/override/LLM-fallback patterns
- `ai/docs/agent-design.md` — agent graph, node I/O, decision tree, tool contract with lane A, chat API (§8)
- `ai/docs/code_check_list.md` — known defects with repro and target task; check before debugging/testing
- `README.md` — what teammates see; keep it in sync when setup or rules change
- Service proposal (requirements source): `[구룡가디언]구룡포 재난 지킴이-구룡포는구룡_최종 복사본.docx` (gitignored;
  contains personal data — never commit). Read with `textutil -convert txt -stdout <file>`
- Architecture diagram: `../아키텍쳐/구룡가디언_architecture.html`
