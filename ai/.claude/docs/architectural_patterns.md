# Architectural patterns

Patterns that recur across `guardian_ai/` and `tests/`. Follow them when replacing stubs in B2–B5.

## 1. Nodes return partial state updates
Every node has the shape `Node = Callable[[GuardianState], dict]` (graph.py:73) and returns only the fields
it changes, never the whole state. Examples: `manager` (graph.py:92), `verify_gate` (graph.py:164).
`GuardianState` is `TypedDict, total=False` (state.py:175), so always read with `state.get(key, default)`.

## 2. Reducers for parallel fan-in, with a RESET sentinel
Fields written by parallel nodes use `Annotated[..., reducer]`:
- `specialist_results` → `merge_results` appends lists (state.py:151)
- `checks` → `merge_checks` merges dicts keyed by check name (state.py:161)
Both accept `RESET` (state.py:148) to clear accumulated values. `manager` sends `RESET` on entry
(graph.py:114-115) so a retry does not mix results from earlier attempts.
Consequence: specialist nodes must return a **list** (graph.py:128); parallel checks must write **distinct keys**
(`"intent"`, `"hallucination"`).

## 3. Gate node + pure router
Decisions with side effects are split in two:
- a *gate node* writes a verdict and bumps counters — `verify_gate` (graph.py:164), `final_check_gate` (graph.py:198)
- a *router* only reads the verdict and returns the next node — `route_verdict` (graph.py:278), `route_polish` (graph.py:287)
Routers never mutate state. Verdict values are typed `Literal`s in state.py (`verdict`, `polish_verdict`).

## 4. Bounded retry loops with safe degradation
Loop limits are constants `MAX_RETRY`, `MAX_POLISH_RETRY` (state.py:211-212), checked in gate nodes.
On exhaustion the graph degrades instead of looping: loop 1 → `fallback` (graph.py:222, `used_fallback=True`);
loop 2 → `finalize` returns the already-verified `verified_draft` (graph.py:213).

## 5. Parallel dispatch via routers
- Dynamic fan-out: `route_specialists` returns `Send(node, state)` per selected agent (graph.py:255, :264),
  or a single node name when nothing is selected.
- Static fan-out: `route_checks` returns a list of node names (graph.py:267); alert mode drops `intent_check`.
All conditional edges declare their possible targets explicitly (graph.py:317, :323, :326, :331) so the
mermaid export is complete.

## 6. Node-name constants + enum-backed identifiers
Node names are module constants (graph.py:57-66); specialist node names are the values of the
`Specialist` enum (state.py:43), and `SPECIALISTS` derives from it (graph.py:70). Tests import the constants
(`G.MANAGER`, `G.SPECIALISTS`) rather than string literals. All enums are `str, Enum` (state.py:19-56)
so they serialize as plain strings.

## 7. Injectable nodes via `build_graph(overrides=...)`
`DEFAULT_NODES` (graph.py:235) maps names to functions; `build_graph` merges `overrides` on top (graph.py:296).
Used by tests to force failures (tests/test_graph_topology.py:60, :76, :88) and intended for incremental
implementation (swap one stub for the real node at a time). Keep topology in `build_graph`, logic in nodes.

## 8. Tools as a contract with mock bodies
Tool functions in tools.py have typed signatures (`Literal` kinds, tools.py:12-14), docstrings naming the
backing table/source and which agents use them, and mock returns sharing one timestamp `_NOW` (tools.py:17).
Every return includes a `source` key so agents can build `Evidence` (state.py:91). Replace bodies only;
keep signatures and keys (agreed with teammate A). Per-agent access is whitelisted in `AGENT_TOOLS` (tools.py:143).

## 9. Evidence-grounded answers, rule-decided actions
- Specialists attach `Evidence` to `SpecialistResult` (state.py:110); hallucination checks compare drafts against it.
- `ActionPlan.steps` (state.py:118) is decided by rules; `guide_ids` cites `ActionGuide` records (state.py:132).
  The LLM only turns steps into sentences.

## 10. Testing pattern
`run()` helper (tests/test_graph_topology.py:25) streams once with `stream_mode=["updates", "values"]` to get
both visited node order and final state from a single execution — do not call `stream` and `invoke`
separately (stateful override counters would run twice). Always pass `recursion_limit` to catch runaway loops.
