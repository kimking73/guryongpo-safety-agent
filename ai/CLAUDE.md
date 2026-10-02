# CLAUDE.md

## Session start (do this first)
1. Read `.claude/docs/timeline.md` → status table, "다음 세션 시작점", "이월 항목", work log.
2. From `코드/`: `git pull` (teammates push to `main`), then `docker compose up -d` and `docker compose ps`
   (db, api, ai all healthy). If `.env` changed since the ai container started: `docker compose up -d --force-recreate ai`.
3. Baseline tests: `.venv/bin/python -m pytest -q` → **89 passed**. `-m db` → 4 passed (needs local db + `AI_DB_*`,
   `AI_MEM_DB_*` in `.env`). `-m live` → 32 passed on gpt-6-luna (routing 13 + B3 injection 13 + memory extractor 6, ~7원).
3a. **OpenAI spend check — warn the user** (user's budget 200,000원/month, user request 2026-10-01): read
   `curl -s localhost:8001/api/ai/usage` (local container), the VM's same URL over ssh, and
   `.venv/bin/python -c "from guardian_ai.usage import UsageTracker; print(UsageTracker().summary())"` (local runs/live
   tests). Sum `cost_krw`; if ≥50% of 200,000원, or a single session/test run burned unusually much, tell the user
   first thing. Also grep ai logs for `OpenAI 사용량 경고`. These are estimates — the key owner's dashboard is the truth.
4. If the user mentions timeline changes, re-read the live timeline artifact
   (https://claude.ai/artifact/S1CWwQbkt9mA7TpQbYbbgB, Artifact tool `action: "read"`) and sync `timeline.md`.
   Its downloaded file may come wrapped in an extra host `<html>` shell — strip it before republishing.
5. Check `docs/agent-design.md` §7 (open questions) and `docs/code_check_list.md` (open: #3, target B5).
6. Route work (B6·B7): `cd ../route && .venv/bin/python -m pytest -q` → **34 passed, 6 deselected** (live 6). Needs
   `../graphhopper/data/guryongpo.osm.pbf` (`../graphhopper/fetch_osm.sh`).

## Session end (do this before finishing)
- Update the status column, "다음 세션 시작점", and "이월 항목" in `.claude/docs/timeline.md`; append one line
  to "작업 기록". If a task finished, mark it done in the live artifact too (only when the user says so).
- If code moved, fix file:line references here, in `architectural_patterns.md`, and in `../CLAUDE.md`.
- Commit; if `git push` is blocked for Claude, ask the user to run `! git push`.

## Current status (2026-10-02, Day 10)
- **Done: B1, B8, B2, B3, B6.** In progress: **B7** (done criterion met, awaiting user's completion call), **B10** (VM up;
  static IP·Caddy·domain left). Next: **B4** (landslide·wind/typhoon·life-safety·location/route agents + rule-based action
  advisor). Plan, carry-overs and work log: `.claude/docs/timeline.md`.
- AI path: `POST /api/chat` → `ChatService.chat` (service.py) → graph. Real nodes: manager (`OpenAIClassifier`, keyword
  fallback), `rain_flood_agent` (`flood.py`: code collects DB data + builds Evidence incl. "기준 위치" and user memory,
  `OpenAIWriter` only phrases, template fallback), `hallucination_check` (`verify.py`: rule number check → `OpenAIFactChecker`).
  `location_route_agent` (`location.py`: nearest safe shelter via `get_safe_shelters` — outside active flood/landslide areas,
  no underground shelters during floods, same rule as the app — + real route via `request_route`, `OpenAILocationWriter`;
  destination from the classifier's `destination` (keyword fallback) → `find_place` user places > DB names > Kakao
  (`KAKAO_REST_KEY`); hazardous destination → route to the safe shelter instead; route returned as `ChatResponse.route`).
  Classifier's `mobility_limited` sets `user.walking_impaired` for the same question (memory still saves it for later).
  Still stubs: landslide/wind/life-safety specialists (return an empty piece; if only stubs are picked the answer is
  `graph.NOT_READY`), action_advisor, intent_check, polish.
  `ChatService()` wires the real nodes; `DEFAULT_NODES`/`ChatService(classifier=…)` stay offline for tests.
- Data: tools read PostgreSQL directly with read-only role `AI_DB_*` (`../db/init/07_ai_readonly.sh`); every tool takes
  `fetch=` and returns `{"available": False, "reason"}` on failure; observations prefer A's simulated values for 6 h like
  the risk engine. `RiskLevel` = DB 5 levels (`.rank`), `ActionGuide` = `action_guides` row. `get_user_profile` is a mock.
- Memory: short-term `InMemorySaver` (60 min after last turn or restart; expired/unknown/other users' ids → new
  conversation), long-term `PostgresStore` in schema `ai_memory` via role `AI_MEM_DB_*` (`../db/init/08_ai_memory.sh`):
  self-stated user facts + conversation summaries, loaded per chat (empty profile fields, manager prompt, flood evidence),
  saved after answering in a thread (`OpenAIMemoryExtractor`); `remember` defaults True; `/api/ai/memory/{uid}` has no
  auth — keep it off the public proxy.
- LLM: OpenAI `gpt-6-luna` (Responses API structured output; reasoning model → no `temperature`; classifier/writer
  effort low, checker medium; SDK retries off). `OPENAI_VERIFY_MODEL` can raise only the checker. Key is borrowed — no
  dashboard cap; `usage.py` estimates and warns at 50/80/100% of 200,000원 (step 3a).
- Latency (2026-10-01, local): ~8 s/question (classify ~2.7 + write ~2.4 + check ~3.0 s, DB 0.02 s), 0 retries in 20;
  one forced retry → 12–15 s. B4/B5 will add LLM calls — set a target before B5.
- Routing: `../route/` + GraphHopper; elderly slope thresholds = 「보도 설치 및 관리 지침」 1/18·1/12 (multipliers
  ×0.5·×0.2·speed ×0.75·stairs ×0.5 still unsourced). Hazards are still the mock GeoJSON (always avoided) — connect
  PostGIS + active risk in B4. Avoidance demo `../route/scripts/avoid_demo.py`: 16/16.
- VM `.env` differs from the Mac's (`AI_DB_PASSWORD`, `AI_MEM_DB_PASSWORD` are VM-only) — never copy the Mac `.env` over it.
- Any LLM failure falls back to keyword routing and logs `라우팅 [키워드 대체]`; a fast (<1 s) answer means fallback.
- Never print `.env` values (a Gemini key leaked once via grep on 2026-09-24; the user rotated it).

## Project overview
구룡가디언 (구룡포 재난 지킴이) — AI part of a disaster-response service for 구룡포 (Pohang), built for the
2026 디지털 트윈 구룡포 AI 해커톤 (team 구룡포는구룡, 3 devs, 21-day plan). A LangGraph multi-agent answers
user questions (chat mode) and generates proactive warnings from the risk engine (alert mode) about landslide,
heavy rain/flood, strong wind/typhoon, and life-safety (fine dust, UV), personalized by user profile
(location, age, mobility, health, occupation).
Sibling parts (not in this folder): FastAPI server + PostgreSQL/PostGIS + risk engine (teammate A),
Flutter app/web (teammate C). This lane (B) also owns GraphHopper routing and GCP deployment.

## Tech stack
- Python ≥3.11 (container 3.12), LangGraph ≥1.0, Pydantic v2, openai SDK, FastAPI + uvicorn, pytest (+httpx)
- LLM: OpenAI `gpt-6-luna` (Responses API, structured outputs); voice planned: Google Cloud STT/TTS (OpenAI GPT-Transcribe/TTS/Realtime is an alternative, decide in B5)
- Routing (planned): GraphHopper + OSM + 국토지리정보원 DEM
- Data behind the tools: 포항 디지털 트윈 API, 기상청 API, 재난안전24, 공공데이터포털, 생활안전지도

## Key directories
| Path | Purpose |
| --- | --- |
| `guardian_ai/state.py` | Enums, Pydantic domain models, reducers, `GuardianState` (state.py:175), retry limits (state.py:211) |
| `guardian_ai/graph.py` | Node functions (stubs), routing functions, `build_graph()` (graph.py:400) |
| `guardian_ai/tools.py` | Read-only DB tools (risk, observations, warnings, messages, zones, facilities, life safety, action guides), `request_route`; allowlist `AGENT_TOOLS` |
| `guardian_ai/flood.py` | Rain/flood agent: `collect` → `build_evidence` → writer or `template_summary`; `make_rain_flood_agent(writer, fetch)` |
| `guardian_ai/verify.py` | Hallucination check: `check_numbers` (rule), `make_hallucination_check(checker)` |
| `guardian_ai/memory.py` | Memory: `make_backends()` → InMemorySaver + PostgresStore in `ai_memory` (fallback InMemoryStore), `CONVERSATION_TTL_MIN`, user facts/episodes load·apply·save·export·forget |
| `guardian_ai/db.py` | Read-only PostgreSQL access (`Database`, `default_fetch`, `conninfo()` from `AI_DB_*`) |
| `guardian_ai/usage.py` | OpenAI token/cost ledger per month (`data/openai_usage.json`, volume `ai-data` in compose), warns at 50/80/100% of `OPENAI_BUDGET_KRW`; `GET /api/ai/usage` |
| `guardian_ai/llm.py` | `make_client()`, `OpenAIClassifier`, `OpenAIWriter` (flood sentences), `OpenAIFactChecker` (`OPENAI_VERIFY_MODEL`), prompts |
| `guardian_ai/service.py` | `ChatRequest`/`ChatResponse`, `ChatService` (service.py:49), checkpointer + `STATE_TYPES` allowlist |
| `guardian_ai/api.py` | FastAPI app for the `ai` container: `/api/chat`, `/api/ai/health` |
| `tests/` | Topology (stub overrides), manager/API (fakes, offline), `test_tools_db.py` (fake fetch), `test_tools_db_live.py` (local DB, `db` marker), `test_routing_live.py` (real OpenAI, `live` marker) |
| `Dockerfile` | `ai` container, port 8001 (service defined in `../docker-compose.yml`) |
| `docs/agent-design.md` | Team-facing design doc (Korean): graph, node I/O, decision tree, tool contract, open questions |
| `.claude/docs/` | Claude-facing notes: timeline/progress, architectural patterns |

## Commands
Run from this directory (`코드/ai`). A project-local venv is used; do not install into the global anaconda env.
```bash
uv venv .venv && uv pip install -p .venv -e ".[dev]"   # setup (already done once)
.venv/bin/python -m pytest -q                         # offline tests (live excluded by addopts)
.venv/bin/python -m pytest -m live -q                 # real OpenAI routing, 13 calls (paid, tiny)
.venv/bin/python -m pytest -m db -q                   # tools against local DB (localhost:5433) + read-only check
docker compose logs -f ai | grep 라우팅                # (from 코드/) per-question routing: [분류기]/[키워드 대체]/[alert 규칙]
.venv/bin/python -c "from guardian_ai.graph import build_graph; print(build_graph().get_graph().draw_mermaid())"  # dump graph
```

## Debugging and testing — check `docs/code_check_list.md` first
Before debugging a failure, writing or running tests, or reviewing code, read `docs/code_check_list.md`.
- **Debugging**: match the symptom against the list before investigating from scratch. Known signatures:
  wrong agent picked in alert mode (#1), unexpected fallback or stale `manager_feedback` on later turns of
  one conversation (#2), polish retry repeating the same mistake (#3), "Deserializing unregistered type"
  warnings (#4). Each entry has repro code and a fix direction.
- **Touching a listed location** (e.g. `manager`, `final_check_gate`, checkpointer setup): fix the listed
  defect in the same change if its target task is the current one, and add the test named in the entry.
- **After a fix**: tick the entry's checkboxes and fill the "해결" column (date + test name). Don't delete entries.
- **New defect found** (in a test run, review, or while debugging) that isn't fixed immediately: add it
  in the same format — location, cause, repro, impact, fix direction, target task.
- Tests pass ≠ defects gone: #3 doesn't show while polish/final check are stubs. #1, #2, #4 are fixed (B2).

## Working rules
- Graph topology or retry limits changed → update `docs/agent-design.md` (sections 1–3) in the same change.
- Tool signatures/return keys are a contract with teammate A (API spec A1); change them only with the
  checklist in `docs/agent-design.md` section 5.
- Every specialist result must carry `Evidence` for any number it states — the hallucination check depends on it.
- Action advice is rule-decided (decision tree), LLM only phrases it; never let the LLM invent action steps.
- Replace stubs one node at a time and add a test per replaced node; existing topology tests must stay green.
- API keys (OpenAI, GCP) go in `.env` only, never committed; provide `.env.example`.
- User-facing text, docs, and code comments are in Korean. The user prefers explanations in Korean.

## Additional documentation
Check these when relevant:
- `../CLAUDE.md` and `../.claude/docs/architectural_patterns.md` — repo-wide setup, compose, env, and cross-service patterns
- `.claude/docs/timeline.md` — dev timeline, B-lane tasks with dependencies/done criteria, schedule risks, work log
- `.claude/docs/architectural_patterns.md` — node/reducer/routing/override/LLM-fallback patterns used across files
- `docs/agent-design.md` — full agent design, node I/O, decision tree, tool contract, open questions
- `docs/code_check_list.md` — known code defects with repro, fix direction, and target task; tick them off when fixed
- Service proposal (source of requirements): `../[구룡가디언]구룡포 재난 지킴이-구룡포는구룡_최종 복사본.docx`
  — read with `textutil -convert txt -stdout <file>`; diagrams are images in `word/media/` (unzip to scratchpad)
- System architecture diagram: `../../아키텍쳐/구룡가디언_architecture.html`
