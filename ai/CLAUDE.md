# CLAUDE.md

## Session start (do this first)
1. Read `.claude/docs/timeline.md` → current status and the next task (B-lane of the dev timeline).
2. Run tests to confirm the baseline: `.venv/bin/python -m pytest -q` (expect 26 passed as of B2; `-m live` calls real Gemini).
3. If the user mentions timeline changes, re-read the live timeline artifact
   (https://claude.ai/artifact/S1CWwQbkt9mA7TpQbYbbgB, via Artifact tool `action: "read"`) and sync `timeline.md`.
4. Check open questions in `docs/agent-design.md` section 7 — some block the next task.
5. Check `docs/code_check_list.md` — known defects, each tagged with the task (B2/B5) where it must be fixed.

## Session end (do this before finishing)
- Update the status column and append one line to "작업 기록" in `.claude/docs/timeline.md`.
- If code moved, fix the file:line references in this file and `architectural_patterns.md`.

## Current status
- **Done: B1 agent structure design** (2026-09-23) — graph topology, state schema, tool specs, 7 topology tests.
  Node bodies are stubs (`graph.py`), tools return mocks (`tools.py`).
- B1 marked complete 2026-09-24 with two items cut from its scope:
  - DB access method with teammate A (direct read-only PostgreSQL vs via FastAPI; `docs/agent-design.md` §7 Q3)
    — still unassigned, not done.
  - Collecting 행동요령 source texts → moved to teammate A's **A7** (static data loader, Day 3–6) as the
    `action_guides` table; B4 now depends on A7. Its format is `ActionGuide` (state.py:132).
- **Done: B2** (2026-09-24) — `make_manager(classify)` (graph.py:144) with `GeminiClassifier` (llm.py), keyword
  fallback on any LLM error/timeout, alert routing table, per-turn reset; `ChatService` + `POST /api/chat` in the
  `ai` container (port 8001). Live routing check (`pytest -m live`): 13/13 on gemini-3.5-flash; gemini-3.6-flash
  only 5/5 before the free quota ran out — rerun `-m live` on 3.6 when quota/billing allows.
  Each question logs one line: `docker compose logs -f ai | grep 라우팅` ([분류기] / [키워드 대체] / [alert 규칙]).
  - **Temporary model**: local `.env` uses `gemini-3.5-flash-lite` with `GEMINI_TIMEOUT_MS=60000` (free-tier Lite
    answers in 17–39 s). Target is `gemini-3.6-flash` / 10 s (`.env.example`). Free tier = 5 req/min, 20 req/day
    per model — pace live tests, don't loop them. Revert both values before demo or when billing is enabled.
  - Never print `.env` values (a grep leaked the Gemini key once on 2026-09-24; user advised to rotate it).
- **Next: B3 (Day 5–6)** — rain/flood agent + hallucination check; tools still mocks until A3.
- **Done: B8 dev environment** (2026-09-24). Teammate 조하린's access and teammates' local verification are
  handled by the user, not tracked here.
  - Repo root is `코드/` (GitHub `kimking73/guryongpo-safety-agent`): `server/` (FastAPI, A), `app/` (Flutter, C),
    `ai/` (this folder), `db/init/`, `secrets/` (gitignored). Setup/rules for the team: `../README.md`.
  - `docker compose up -d --build` from `코드/` runs `db` (PostGIS, host port **5433**) and `api` (`/api/health`, port 8000).
    Compose project name is fixed to `guardian` (Korean folder name breaks auto-naming).
    Local-only settings live in `docker-compose.override.yml`; servers run `-f docker-compose.yml` without it.
  - GCP project `guryong-guardian-0924` (asia-northeast3), billing account 01B546-5CB118-24C5BC, 0원 budget alert.
    Firebase on the same project: anonymous auth + FCM on. Service account key for firebase-admin in
    `../secrets/firebase-admin.json` (FCM send role only).

## Project overview
구룡가디언 (구룡포 재난 지킴이) — AI part of a disaster-response service for 구룡포 (Pohang), built for the
2026 디지털 트윈 구룡포 AI 해커톤 (team 구룡포는구룡, 3 devs, 21-day plan). A LangGraph multi-agent answers
user questions (chat mode) and generates proactive warnings from the risk engine (alert mode) about landslide,
heavy rain/flood, strong wind/typhoon, and life-safety (fine dust, UV), personalized by user profile
(location, age, mobility, health, occupation).
Sibling parts (not in this folder): FastAPI server + PostgreSQL/PostGIS + risk engine (teammate A),
Flutter app/web (teammate C). This lane (B) also owns GraphHopper routing and GCP deployment.

## Tech stack
- Python ≥3.11, LangGraph ≥0.6, Pydantic v2, pytest
- LLM (planned): Gemini 3.6 Flash; voice: Google Cloud STT/TTS (fallback: gemini-3.1-live-preview)
- Routing (planned): GraphHopper + OSM + 국토지리정보원 DEM
- Data behind the tools: 포항 디지털 트윈 API, 기상청 API, 재난안전24, 공공데이터포털, 생활안전지도

## Key directories
| Path | Purpose |
| --- | --- |
| `guardian_ai/state.py` | Enums, Pydantic domain models, reducers, `GuardianState` (state.py:175), retry limits (state.py:211) |
| `guardian_ai/graph.py` | Node functions (stubs), routing functions, `build_graph()` (graph.py:400) |
| `guardian_ai/tools.py` | DB lookup tool specs with mock returns; per-agent tool allowlist `AGENT_TOOLS` (tools.py:143) |
| `tests/` | Graph topology tests using stub-node overrides |
| `docs/agent-design.md` | Team-facing design doc (Korean): graph, node I/O, decision tree, tool contract, open questions |
| `.claude/docs/` | Claude-facing notes: timeline/progress, architectural patterns |

## Commands
Run from this directory (`코드/ai`). A project-local venv is used; do not install into the global anaconda env.
```bash
uv venv .venv && uv pip install -p .venv -e ".[dev]"   # setup (already done once)
.venv/bin/python -m pytest -q                         # run all tests
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
- Tests pass ≠ defects gone: #2–#4 don't show in the current suite (fresh state per run, stub nodes).

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
- `.claude/docs/timeline.md` — dev timeline, B-lane tasks with dependencies/done criteria, schedule risks, work log
- `.claude/docs/architectural_patterns.md` — node/reducer/routing/override patterns and conventions used across files
- `docs/agent-design.md` — full agent design, node I/O, decision tree, tool contract, open questions
- `docs/code_check_list.md` — known code defects with repro, fix direction, and target task; tick them off when fixed
- Service proposal (source of requirements): `../[구룡가디언]구룡포 재난 지킴이-구룡포는구룡_최종 복사본.docx`
  — read with `textutil -convert txt -stdout <file>`; diagrams are images in `word/media/` (unzip to scratchpad)
- System architecture diagram: `../../아키텍쳐/구룡가디언_architecture.html`
