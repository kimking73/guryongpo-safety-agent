# CLAUDE.md

## Session start (do this first)
1. Read `.claude/docs/timeline.md` → status table, "다음 세션 시작점", "이월 항목", work log.
2. From `코드/`: `git pull` (teammates push to `main`), then `docker compose up -d` and `docker compose ps`
   (db, api, ai all healthy). If `.env` changed since the ai container started: `docker compose up -d --force-recreate ai`.
3. Baseline tests: `.venv/bin/python -m pytest -q` → **26 passed, 13 deselected** as of B2.
   Don't run `-m live` casually — it spends Gemini free-tier quota (5/min, 20/day per model).
4. If the user mentions timeline changes, re-read the live timeline artifact
   (https://claude.ai/artifact/S1CWwQbkt9mA7TpQbYbbgB, Artifact tool `action: "read"`) and sync `timeline.md`.
   Its downloaded file may come wrapped in an extra host `<html>` shell — strip it before republishing.
5. Check `docs/agent-design.md` §7 (open questions) and `docs/code_check_list.md` (open: #3, target B5).
6. Route work (B6·B7): `cd ../route && .venv/bin/python -m pytest -q` → **19 passed, 2 deselected**. Needs
   `../graphhopper/data/guryongpo.osm.pbf` (`../graphhopper/fetch_osm.sh`).

## Session end (do this before finishing)
- Update the status column, "다음 세션 시작점", and "이월 항목" in `.claude/docs/timeline.md`; append one line
  to "작업 기록". If a task finished, mark it done in the live artifact too (only when the user says so).
- If code moved, fix file:line references here, in `architectural_patterns.md`, and in `../CLAUDE.md`.
- Commit; if `git push` is blocked for Claude, ask the user to run `! git push`.

## Current status (2026-09-26, Day 4)
- **Done: B1, B8, B2.** **In progress: B6** (moved ahead of B3, which waits for A1·A3). B6 steps 1–2 done: `../route/`
  (`POST /api/route`, avoids mock flood/landslide zones + manholes, reports `avoided`/`still_inside`) + `../graphhopper/`.
  B6 meets its done criterion on mock data; mark complete only when the user says so.
  Details and carry-over items: `.claude/docs/timeline.md`.
- AI path today: `POST /api/chat` (api.py:34) → `ChatService.chat` (service.py:60) → graph with
  `make_manager(GeminiClassifier())` (graph.py:144, llm.py:109). Only the manager is real; specialists,
  advisor, checks, polish are stubs (graph.py:223-265), tools return mocks sharing `_NOW` (tools.py:17).
  So `answer` is placeholder text like "rain_flood_agent stub"; `selected_agents` is the real output.
- Gemini: AI Studio key in `../.env` (project `guryong-guardian-0924`). **Temporary local model**
  `gemini-3.5-flash-lite` + `GEMINI_TIMEOUT_MS=60000` (Lite free tier answers in 17–39 s, sometimes 504).
  Target is `gemini-3.6-flash` / 10 s as in `../.env.example` — revert before demo or once billing is on.
  Live routing check: 13/13 on gemini-3.5-flash; 3.6 only 5/5 before quota ran out (rerun pending).
- Any LLM failure falls back to keyword routing and logs `라우팅 [키워드 대체]`; a fast (<1 s) answer means fallback.
- Never print `.env` values (the Gemini key leaked once via grep on 2026-09-24; the user rotated it).

## Project overview
구룡가디언 (구룡포 재난 지킴이) — AI part of a disaster-response service for 구룡포 (Pohang), built for the
2026 디지털 트윈 구룡포 AI 해커톤 (team 구룡포는구룡, 3 devs, 21-day plan). A LangGraph multi-agent answers
user questions (chat mode) and generates proactive warnings from the risk engine (alert mode) about landslide,
heavy rain/flood, strong wind/typhoon, and life-safety (fine dust, UV), personalized by user profile
(location, age, mobility, health, occupation).
Sibling parts (not in this folder): FastAPI server + PostgreSQL/PostGIS + risk engine (teammate A),
Flutter app/web (teammate C). This lane (B) also owns GraphHopper routing and GCP deployment.

## Tech stack
- Python ≥3.11 (container 3.12), LangGraph ≥1.0, Pydantic v2, google-genai, FastAPI + uvicorn, pytest (+httpx)
- LLM: Gemini via AI Studio key (target gemini-3.6-flash); voice planned: Google Cloud STT/TTS (fallback: gemini-3.1-live-preview)
- Routing (planned): GraphHopper + OSM + 국토지리정보원 DEM
- Data behind the tools: 포항 디지털 트윈 API, 기상청 API, 재난안전24, 공공데이터포털, 생활안전지도

## Key directories
| Path | Purpose |
| --- | --- |
| `guardian_ai/state.py` | Enums, Pydantic domain models, reducers, `GuardianState` (state.py:175), retry limits (state.py:211) |
| `guardian_ai/graph.py` | Node functions (stubs), routing functions, `build_graph()` (graph.py:400) |
| `guardian_ai/tools.py` | DB lookup tool specs with mock returns; per-agent tool allowlist `AGENT_TOOLS` (tools.py:143) |
| `guardian_ai/llm.py` | Gemini client, `GeminiClassifier` (llm.py:109), prompt (`SYSTEM_PROMPT` :50, `build_prompt` :88) |
| `guardian_ai/service.py` | `ChatRequest`/`ChatResponse`, `ChatService` (service.py:49), checkpointer + `STATE_TYPES` allowlist |
| `guardian_ai/api.py` | FastAPI app for the `ai` container: `/api/chat`, `/api/ai/health` |
| `tests/` | Topology (stub overrides), manager/API (fakes, offline), `test_routing_live.py` (real Gemini, `live` marker) |
| `Dockerfile` | `ai` container, port 8001 (service defined in `../docker-compose.yml`) |
| `docs/agent-design.md` | Team-facing design doc (Korean): graph, node I/O, decision tree, tool contract, open questions |
| `.claude/docs/` | Claude-facing notes: timeline/progress, architectural patterns |

## Commands
Run from this directory (`코드/ai`). A project-local venv is used; do not install into the global anaconda env.
```bash
uv venv .venv && uv pip install -p .venv -e ".[dev]"   # setup (already done once)
.venv/bin/python -m pytest -q                         # offline tests (live excluded by addopts)
.venv/bin/python -m pytest -m live -q                 # real Gemini routing, ~3 min, uses 13 quota calls
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
- API keys (Gemini, GCP) go in `.env` only, never committed; provide `.env.example`.
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
