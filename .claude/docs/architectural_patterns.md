# Architectural patterns (repo-wide)

Patterns shared across services (`server/`, `ai/`, compose). AI-internal LangGraph patterns live in
`ai/.claude/docs/architectural_patterns.md`.

## 1. Configuration only through the root `.env`
- One `.env` at the repo root feeds every container via `env_file: .env` (docker-compose.yml:35, :54).
- Required values fail fast with `${VAR:?message}` (docker-compose.yml:20-22); optional ports use defaults
  `${VAR:-default}` (docker-compose.yml:43, :56; docker-compose.override.yml:8).
- Values derived from other keys are composed in compose, not in code: `DATABASE_URL` (docker-compose.yml:38),
  consumed as-is by the server (server/app/main.py:19).
- Code reads env with a code-level default where one is safe (ai/guardian_ai/llm.py:119, :124) and raises a clear
  error where none is (ai/guardian_ai/llm.py:116-118).
- `.env.example` is the contract: every key present, grouped by area prefix, comments on their own line
  (.env.example:2-8). Inline comments after a value are read as part of the value by compose.

## 2. Compose base + local override
- `docker-compose.yml` must be deployable as-is on the server: no host DB port, no source mounts.
- `docker-compose.override.yml` (auto-merged locally) adds only dev conveniences: DB host port (:8), source
  mounts + `uvicorn --reload` for each Python service (:12-14, :18-20).
- Server runs `docker compose -f docker-compose.yml ...` to drop the override.
- Project name is pinned (docker-compose.yml:12) because the Korean folder name yields an empty default.

## 3. Uniform Python service container
- Same shape in server/Dockerfile, ai/Dockerfile and route/Dockerfile: `python:3.12-slim` (:1), install dependencies by reading
  `[project].dependencies` from `pyproject.toml` (:7) so the list lives in one place, copy the package, run uvicorn (:12).
- Dependencies layer is copied/installed before source so code edits reuse the cache.
- Each service has its own `.dockerignore` excluding venvs, caches (and tests/docs for ai).

## 4. HTTP conventions: `/api` prefix, health per service
- Every route is under `/api/...` so a single reverse proxy (Caddy, B10) can split by path:
  `/api/chat` → ai (ai/guardian_ai/api.py:34), `/api/route` → route (route/guardian_route/api.py:35), the rest → server.
  Ports: api 8000, ai 8001, route 8002; graphhopper 8989 is internal (exposed only by the override).
- Each service exposes a cheap health route — `/api/health` (server/app/main.py:15),
  `/api/ai/health` (ai/guardian_ai/api.py:29), `/api/route/health` (route/guardian_route/api.py:30) — and compose healthchecks call it with the stdlib
  (docker-compose.yml:45, :58, :90; slim images have no curl). `db` uses `pg_isready` (docker-compose.yml:27);
  `graphhopper` uses curl, which its Temurin JRE image ships (docker-compose.yml:71).
- All services: `restart: unless-stopped` (docker-compose.yml:18, :34, :53, :67, :80); dependents wait on
  `condition: service_healthy`.
- Request/response bodies are Pydantic models (ai/guardian_ai/service.py:26, :35); FastAPI validates and returns 422.

## 5. Degrade, don't fail
A disaster service must keep answering when a dependency breaks. Recurring shape: catch broadly at the boundary,
log, return a reduced-but-valid result.
- Health reports `db: "error"` instead of raising (server/app/main.py:22-23); route reports `graphhopper: "error"`
  (route/guardian_route/service.py:52).
- Route engine down/slow → 503 with a Korean reason, never a made-up path (route/guardian_route/api.py:39-44).
- LLM failure → keyword classification (ai/guardian_ai/graph.py:185-189).
- Verification exhausted → safe fixed answer node (ai/guardian_ai/graph.py:326).
- Timeouts are short by default (ai/guardian_ai/llm.py:24) so fallback kicks in quickly.

## 6. Injectable dependencies with production defaults
- Constructors/factories accept the dependency and build the real one only when omitted:
  `ChatService(classifier=None, checkpointer=None)` (ai/guardian_ai/service.py:50),
  `GeminiClassifier(client=None, model=None)` (ai/guardian_ai/llm.py:112), `make_manager(classify)` (ai/guardian_ai/graph.py:144),
  `RouteService(client=None)` (route/guardian_route/service.py:39), `GraphHopperClient(..., transport=None)` (route/guardian_route/gh.py:27)
  — tests pass `httpx.MockTransport` as a fake GraphHopper (route/tests/test_route.py:18).
- FastAPI wiring uses a cached provider + `Depends` (ai/guardian_ai/api.py:23, :35); tests swap it via
  `app.dependency_overrides` (ai/tests/test_api.py:12).
- Heavy/secret-needing imports are deferred into the default branch so tests run without keys
  (ai/guardian_ai/service.py:50-54).

## 7. Secrets handling
- Gitignore blocks `.env*` except the example, everything in `secrets/` except `.gitkeep`, and `*.docx`
  (.gitignore:2-9). File secrets are referenced by path from `.env` (`FIREBASE_CREDENTIALS`).
- The proposal docx holds personal data and was purged from git history once; keep it out.
- `.gitattributes` forces LF so Windows (WSL) teammates don't produce CRLF churn.

## 8. Test layering: offline by default, live on demand
- Default test runs need no network or keys: fakes replace external clients
  (ai/tests/test_manager.py `FakeModels`; `ChatService(classifier=G.keyword_classify)` in ai/tests/test_api.py:11).
- Tests that hit paid/limited APIs carry a `live` marker excluded by `addopts` (ai/pyproject.toml:27-28), pace
  calls to the free-tier limit, and retry transient 429/503/timeouts.
- Multi-turn behavior is tested through the real checkpointer path, not fresh-state invokes.
