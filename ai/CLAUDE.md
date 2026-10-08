# CLAUDE.md

## Session start (do this first)
1. Read `.claude/docs/timeline.md` → status table, "다음 세션 시작점", "이월 항목", work log.
2. From `코드/`: `git pull` (teammates push to `main`), then `docker compose up -d` and `docker compose ps`
   (db, api, ai all healthy). If `.env` changed since the ai container started: `docker compose up -d --force-recreate ai`.
3. Baseline tests: `.venv/bin/python -m pytest -q` → **208 passed** (2026-10-08). `-m "db and not live"` needs local db + `AI_DB_*`
   in `.env` (plain `-m db` also runs paid live tests). `-m live` calls real OpenAI (routing, B3 injection, extractor; a few 원).
   If `docker compose ps` hangs, restart the OrbStack app (happened 2026-10-08); VM checks still work.
   Other lanes' baselines: server 212 passed·8 skipped, route 68, app 101 with 7 known failures (see timeline "다음 세션 시작점";
   run Flutter on an ASCII-path copy).
3a. **OpenAI spend check — warn the user** (user's budget 200,000원/month, user request 2026-10-01): read
   `curl -s localhost:8001/api/ai/usage` (local container), the VM's same URL over ssh, and
   `.venv/bin/python -c "from guardian_ai.usage import UsageTracker; print(UsageTracker().summary())"` (local runs/live
   tests). Sum `cost_krw`; if ≥50% of 200,000원, or a single session/test run burned unusually much, tell the user
   first thing. Also grep ai logs for `OpenAI 사용량 경고`. These are estimates — the key owner's dashboard is the truth.
4. If the user mentions timeline changes, re-read the live timeline artifact
   (https://claude.ai/artifact/H3ofVAbENCmCvRtAvaGLAi — 28-day version since 2026-10-03, Artifact tool `action: "read"`) and sync `timeline.md`.
   Its downloaded file may come wrapped in an extra host `<html>` shell — strip it before republishing.
5. Check `docs/agent-design.md` §7 (open questions) and `docs/code_check_list.md` (#1–6 fixed, #7 mitigated — recheck in a demo scenario).
6. Route work (B6·B7): `cd ../route && .venv/bin/python -m pytest -q` → **68 passed** (live deselected). Needs
   `../graphhopper/data/guryongpo.osm.pbf` (`../graphhopper/fetch_osm.sh`).

## Session end (do this before finishing)
- Update the status column, "다음 세션 시작점", and "이월 항목" in `.claude/docs/timeline.md`; append one line
  to "작업 기록". If a task finished, mark it done in the live artifact too (only when the user says so).
- If code moved, fix file:line references here, in `architectural_patterns.md`, and in `../CLAUDE.md`.
- Commit; if `git push` is blocked for Claude, ask the user to run `! git push`.

## Current status (2026-10-08, Day 16)
- Timeline is 28 days (Day 1 = 2026-09-23; Day 21 = extra features integration). **Done: B1, B8, B2, B3, B6, B7.**
  **B10** done criteria met (https://34-64-177-195.nip.io). **B11** 1st pass + AI link (`request_sea_route`, 10-07). **C8** built and deployed.
  **B4**: only the proactive alert message function for A5 is left (+ recovery/support agent added 10-08). **B5**: voice deferred (no GCP key → 503).
  Marking B4/B5/B10/J1/B11 done waits for the user. B also changed lanes A and C on the user's request (10-05~08: demo mode,
  login forced, server profile as the single user-info store, `care.profile_updates`, **app redesign to `../web-prototype/`**) —
  sharing with 조하린·김다인 is pending (timeline 이월 항목). Next: timeline "다음 세션 시작점".
- User info (2026-10-08): the server profile (`user_profiles`·`user_places`) is the only store — read by `tools.get_user_profile`,
  written after each signed-in answer by `profile_sync.ProfileWriter` with the user's own token (+ log `/api/v1/user/profile-updates`).
  `ai_memory.store` is retired (data kept). Signed-in = token uid == request user_id (`api._signed_in`); demo chats also write.
- Recovery/support agent (2026-10-08, `recovery.py`): 6th specialist; `support_programs` (9 rows) → [공통 보험]·[공통 피해 신고·복구]·
  [내 직업 지원·복구] by the profile's occupation; only DB programs, else "등록된 제도 없음". Disaster agents must not write
  "지원 정보 확인 불가" (`flood.SUPPORT_TOPICS` sentences are stripped) or mixed questions fail verification.
- AI path: `POST /api/chat` → `ChatService.chat` (service.py) → graph. Real nodes: manager (`OpenAIClassifier`, keyword
  fallback), `rain_flood_agent` (`flood.py`: code collects DB data + builds Evidence incl. "기준 위치" and user memory,
  `OpenAIWriter` only phrases, template fallback), `hallucination_check` (`verify.py`: rule number check → `OpenAIFactChecker`).
  `location_route_agent` (`location.py`: nearest safe shelter via `get_safe_shelters` — outside active flood/landslide areas,
  no underground shelters during floods, same rule as the app — + real route via `request_route`, `OpenAILocationWriter`;
  destination from the classifier's `destination` (keyword fallback) → `find_place` user places > DB names > Kakao
  (`KAKAO_REST_KEY`); hazardous destination → route to the safe shelter instead; route returned as `ChatResponse.route`).
  Classifier's `mobility_limited` sets `user.walking_impaired` for the same question (the profile writer saves it to the server profile for later).
  `landslide_agent`·`wind_typhoon_agent`·`life_safety_agent` (`specialists.py`: same shape, `make_specialist` + `OpenAISpecialistWriter`;
  unavailable data also goes into evidence so the checker accepts "확인할 수 없음"). `action_advisor` (`action.py`): rule picks
  official guides (disaster·phase·targets) → `OpenAIActionWriter` personalizes "지금 할 일" from them only → guides go into
  `ActionPlan.evidence` for the checker; `call_emergency` rule (D3); `decide_phase` (before/during/after 24 h/none) via
  `make_manager(phase_of=…)`. The advisor follows the user's decision tree (`action.decide`, agent-design.md 4절):
  phase → danger (`hazards_at`) → can_move / damage (classifier fields from the conversation, keyword fallback) → 119 /
  shelter route / one follow-up question; response `decision_path`, `follow_up`. Forecasts: `tools.get_forecast` (KMA
  ultra-short + short, evidence named 오늘/내일/모레). Default graph (tests) uses no-DB advisor and phase 'during'.
  `ChatService()` wires the real nodes; `DEFAULT_NODES`/`ChatService(classifier=…)` stay offline for tests.
- B5 (2026-10-03, in progress — only the real Google voice round trip is left, waiting for `secrets/gcp-voice.json`):
  intent check rides on the content checker's call (`OpenAIFactChecker(checks_intent=True)`, effort low by default —
  `OPENAI_VERIFY_EFFORT`; the service's `intent_check` node is a no-op). `polish.py`: `build_card` (code picks chips from
  Evidence) + `OpenAIPolisher` only for drafts > 600 chars + `voice_text`; `make_final_check` = rule number check →
  `polish_feedback` (#3 fixed). `ChatResponse.card`·`voice_text`·`timings`. `voice.py` (ffmpeg → Google STT/TTS v1),
  `api.py` `/api/voice` (multipart) and `/api/tts`; no key → 503. Latency targets: text 15 s, voice 20 s; measured text
  7–19 s, one retry 30–35 s. Live tree test: `tests/test_tree_live.py -m "live and db"` (11 cases, ~6 min).
- Data: tools read PostgreSQL directly with read-only role `AI_DB_*` (`../db/init/07_ai_readonly.sh`); every tool takes
  `fetch=` and returns `{"available": False, "reason"}` on failure; observations prefer A's simulated values for 6 h like
  the risk engine. `RiskLevel` = DB 5 levels (`.rank`), `ActionGuide` = `action_guides` row. `get_user_profile` reads `users`·`user_profiles`·`user_places` by Firebase uid (2026-10-08): for a signed-in chat (token uid = user_id, api.py `_signed_in`) the server profile is the source of truth, app-sent values only fill gaps.
- Memory: short-term `InMemorySaver` (60 min after last turn or restart; expired/unknown/other users' ids → new
  conversation). User info = the server profile only (user decision 2026-10-08): after answering, a background thread runs
  `OpenAIMemoryExtractor` and `profile_sync.ProfileWriter` writes the facts to `POST /api/v1/user` + `/api/v1/user/places`
  **with the user's own token** (no DB write grant for the AI), then logs each applied fact to `POST /api/v1/user/profile-updates`
  (`care.profile_updates`, shown on the app's profile screen as 'AI가 대화에서 수집한 정보'); the app's profile screen reads the same rows
  (`app/lib/services/account_sync.dart` `pullProfile`). The old long-term store (`ai_memory` schema) is no longer read or
  written — data and the `AI_MEM_DB_*` role are kept; the memory APIs are gone. `state.user_memory` is always empty.
- LLM: OpenAI `gpt-6-luna` (Responses API structured output; reasoning model → no `temperature`; classifier/writer
  effort low, checker low since B5 (`OPENAI_VERIFY_EFFORT`); SDK retries off). `OPENAI_VERIFY_MODEL` can raise only the checker. Key is borrowed — no
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
| `guardian_ai/state.py` | Enums, Pydantic domain models, reducers, `GuardianState` (state.py:192), retry limits (state.py:234) |
| `guardian_ai/graph.py` | Default (stub) nodes, manager (keyword fallbacks, follow-up continuation), routing functions, `build_graph()` (graph.py:470) |
| `guardian_ai/tools.py` | Read-only DB tools (risk, observations, warnings, messages, zones, facilities, life safety, action guides), `request_route`; allowlist `AGENT_TOOLS` |
| `guardian_ai/flood.py` | Rain/flood agent: `collect` → `build_evidence` → writer or `template_summary`; `make_rain_flood_agent(writer, fetch)` |
| `guardian_ai/verify.py` | Hallucination + intent check: `check_numbers` (rule), `make_hallucination_check(checker)` (checker may return (fact, intent)) |
| `guardian_ai/specialists.py` | Landslide·wind/typhoon·life-safety agents (`make_specialist`) |
| `guardian_ai/recovery.py` | Recovery/support agent (2026-10-08): `support_programs` → [공통 보험]·[공통 피해 신고·복구]·[내 직업 지원·복구] by the profile's occupation (`job_targets`), question hazard filter (`hazard_of`), `make_recovery_support_agent`; advisor skips the decision tree when it is the only agent |
| `guardian_ai/location.py` | Location/route agent: safe shelter, `find_place` destination, route |
| `guardian_ai/action.py` | Action advisor: `decide_phase`, decision tree `decide`, `pick_guides`, `make_action_advisor` |
| `guardian_ai/polish.py` | B5: `build_card`, `fallback_voice`, `make_polish(polisher)` (LLM only > 600 chars), `make_final_check()` (rule → `polish_feedback`) |
| `guardian_ai/voice.py` | B5 voice (deferred): `to_pcm16k` (ffmpeg), `GoogleVoice.stt/.tts` (key `secrets/gcp-voice.json`) |
| `guardian_ai/memory.py` | `CONVERSATION_TTL_MIN` (short-term conversation memory; long-term store retired 2026-10-08) |
| `guardian_ai/profile_sync.py` | Chat facts → server profile: `to_patch`, `ProfileWriter.apply(token, facts)` (POST /api/v1/user, places), `describe` |
| `guardian_ai/db.py` | Read-only PostgreSQL access (`Database`, `default_fetch`, `conninfo()` from `AI_DB_*`) |
| `guardian_ai/usage.py` | OpenAI token/cost ledger per month (`data/openai_usage.json`, volume `ai-data` in compose), warns at 50/80/100% of `OPENAI_BUDGET_KRW`; `GET /api/ai/usage` |
| `guardian_ai/llm.py` | `make_client()`, `OpenAIClassifier`, `OpenAIWriter` (flood sentences), `OpenAIFactChecker` (`OPENAI_VERIFY_MODEL`, `OPENAI_VERIFY_EFFORT`, `checks_intent`), specialist/action/polish writers, prompts |
| `guardian_ai/service.py` | `ChatRequest`/`ChatResponse`, `ChatService` (service.py:119; real nodes wired in `__init__`, `chat()` streams for `timings`), `Card`·`RouteInfo`, checkpointer + `STATE_TYPES` allowlist |
| `guardian_ai/api.py` | FastAPI app for the `ai` container: `/api/chat`, `/api/voice`, `/api/tts`, `/api/ai/health`, `/api/ai/usage` |
| `tests/` | Topology (stub overrides), manager/API (fakes, offline), `test_tools_db.py` (fake fetch), `test_tools_db_live.py` (local DB, `db` marker), `test_routing_live.py` (real OpenAI, `live` marker), `test_b4.py`·`test_b5.py`·`test_voice.py` (offline), `test_tree_live.py` (decision tree, `live and db`, ~6 min) |
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
