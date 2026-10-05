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

Lanes: **A** server/DB/data collection/risk engine (`server/`, `db/`) · **B** AI + routing + infra (`ai/`, `route/`,
`graphhopper/`, compose, GCP) · **C** Flutter app/web (`app/`). The user of this repo works lane B.

## Tech stack
- Python 3.12 containers (local venvs ≥3.11), FastAPI + uvicorn for every HTTP service
- PostgreSQL 17 + PostGIS 3.5 (`imresamu/postgis`, multi-arch — official image lacks arm64)
- AI: LangGraph ≥1.0, Pydantic v2, openai SDK (`gpt-6-luna`, Responses API; switched from Gemini 2026-10-01); voice: Google Cloud STT/TTS code in place (B5), deferred by the user — no key yet
- Routing (B6 done, B7 in progress): GraphHopper 11 (Java 21, foot profile, flexible mode) + OSM + elevation (SRTM 90m, or 국토지리정보원 DEM via `graphhopper/build_dem.sh`)
- Client (planned, C2): Flutter; Firebase anonymous auth + FCM
- Infra: Docker Compose (OrbStack on Mac, Docker Desktop + WSL2 on Windows); GCP project
  `guryong-guardian-0924` (asia-northeast3); deploy VM (another GCP project, static IP 34.64.177.195) + Caddy at
  https://34-64-177-195.nip.io (B10, see README "배포 서버")

## Key directories
| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Services shared by local and server: `db`, `api`, `collector`, `ai`, `graphhopper`, `route`; one-shot `loader` (profile `tools`, `docker compose run --rm loader`); `caddy` (profile `deploy`, VM only via `COMPOSE_PROFILES=deploy`); project name fixed |
| `docker-compose.override.yml` | Local-only: DB host port 5433, graphhopper 8989, code mounts + `--reload` |
| `server/` | Lane A: FastAPI API (`/api/v1`; real: `/api/health`, `/api/v1/risk*`, map layers, `/dashboard` (app/widgets.py), `/support-programs`, user·alerts·admin; leftovers return `X-Mock: true`), `collector/` (Pohang DT + KMA ingestion, APScheduler, runs as the `collector` service), `risk/` (flood risk engine → `risk_assessments`), `spec/openapi.yaml`, `mock/`, `tools/`. See `server/README.md` |
| `ai/` | LangGraph multi-agent + `POST /api/chat` (also `/api/voice`·`/api/tts`, 503 without `secrets/gcp-voice.json`); reads the DB directly with a read-only role (B3). See `ai/CLAUDE.md` |
| `route/` | Route server (lane B): `POST /api/route` (avoids the risk engine's current flood/landslide areas ≥ advisory via api `/api/v1/risk/areas` (hazards.py `RiskAreaHazardSource`, 60 s cache; no manholes), re-requests with the zone widened when GraphHopper misses a crossing (service.py `_widen_until_clear`), per-profile slope/steps rules (profiles.py), route/guardian_route/service.py:88), `POST /api/route/check` (reroute while moving), `POST /api/route/sea` (B11 1st pass: sea → nearest port → land; `sea.py` — sea leg = grid shortest path 15 m clear of land+breakwaters, straightened; land polygon `data/land.geojson` from OSM coastline + breakwaters via `scripts/build_land.py`, 12 ports `data/ports.geojson` via `scripts/build_ports.py` (also DB seed `db/init/10_seed_ports.sql`); logic will change when B11 is finalized, response shape fixed); fixed demo zones `route/data/hazards.sample.geojson` only via `ROUTE_HAZARDS_FILE`; elderly slope thresholds 1/18·1/12 (profiles.py); avoidance demo `route/scripts/avoid_demo.py` (outputs `route/out/`, gitignored); tests in `route/tests/` |
| `graphhopper/` | GraphHopper 11 image + `config.yml` (foot, no CH); `fetch_osm.sh` rebuilds `data/guryongpo.osm.pbf` (committed, © OSM contributors ODbL; rest of `data/` gitignored); `build_dem.sh` turns 국토지리정보원 DEM in `dem/ngii/` into `data/dem-hgt/`; `entrypoint.sh` picks DEM (NGII if present, else SRTM) and rebuilds the graph when it changes (dem/ngii/ gitignored) |
| `app/` | Lane C: Flutter app/web. C8 screens (household + separate sensitive-info consent, patrol dashboard for responder/admin only, visit input, delegated registration, sea route) in `lib/patrol_screens.dart`. Mock by default; `--dart-define=APP_MODE=remote` connects to api/ai/route (J1, `lib/repositories/remote_repository.dart`; base URLs `API_BASE_URL`/`AI_BASE_URL`/`ROUTE_BASE_URL`). See `app/README.md` |
| `db/init/` | SQL run once on an empty DB volume: 00 PostGIS, 01 schema, 02–06 seeds (rules/stations/manholes, landslide zones, knowledge, shelters, medical); seeds are re-runnable and re-applied to an existing DB by `server/loader` (A7) — lane A. `07_ai_readonly.sh` (lane B) creates the AI's SELECT-only role from `AI_DB_*`; `08_ai_memory.sh` (lane B) creates schema `ai_memory` + role `AI_MEM_DB_*` for the AI's long-term memory (LangGraph PostgresStore; no access to public) |
| `deploy/` | B10: `Caddyfile` (HTTPS for `DEPLOY_DOMAIN`; /api/chat·voice·tts·ai → ai, /api/route → route, other /api → api, / → Flutter web; blocks /api/ai/memory·/api/ai/usage·/api/v1/internal), `deploy.sh` (run on VM: backup → pull → loader → rebuild → health), `push_web.sh` (run on Mac: build web in an ASCII temp dir → rsync to VM `deploy/web/`, gitignored); Firebase web config in `deploy/web-defines.json` (gitignored) |
| `secrets/` | Credential files, gitignored except `.gitkeep` (e.g. `firebase-admin.json`) |
| `.env.example` | Every env key with local defaults; rules in its header (.env.example:2-8) |
| `README.md` | Team-facing setup (Mac/Windows), common commands, env and service rules |

## Commands
Run from this directory (`코드/`).
```bash
cp .env.example .env                         # first time; fill keys from the team's private channel
./graphhopper/fetch_osm.sh                   # only to refresh the road network (guryongpo.osm.pbf, ~300KB, is committed)
docker compose up -d --build                 # start db, api, ai, graphhopper, route (override auto-merged)
docker compose ps                            # all services should be (healthy)
curl localhost:8000/api/health               # {"status":"ok","db":"ok"}
curl localhost:8001/api/ai/health            # {"status":"ok"}
curl localhost:8002/api/route/health         # {"status":"ok","graphhopper":"ok"}
docker compose logs -f ai | grep 라우팅       # per-question AI routing result
docker compose up -d --force-recreate ai     # after editing .env (env is read at container start)
docker compose down [-v]                     # stop (-v also wipes DB data, re-runs db/init)
docker compose run --rm loader               # re-apply db/init seeds 02– to an existing DB (keeps observations/users)
docker compose exec db sh /docker-entrypoint-initdb.d/07_ai_readonly.sh  # AI read-only role on an existing DB (after `docker compose up -d db` so db sees AI_DB_*)
docker compose -f docker-compose.yml up -d   # server mode: no override, DB not exposed
cd ai && .venv/bin/python -m pytest -q       # AI tests (offline); `-m live` calls real OpenAI
cd route && .venv/bin/python -m pytest -q    # route tests (fake GraphHopper); `-m live` needs graphhopper on :8989
cd app && flutter run -d chrome --dart-define=APP_MODE=remote   # app on real servers (omit the define for mock data)
cd app && flutter test                       # app tests (analyze crashes on the Korean path — run it on a copy in an ASCII path)
cd app && flutter test --platform chrome      # same tests in Chrome — web-only bugs (e.g. `~` is unsigned 32-bit in JS) show only here
./graphhopper/build_dem.sh                   # after putting 국토지리정보원 DEM files in graphhopper/dem/ngii/; then restart graphhopper
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
