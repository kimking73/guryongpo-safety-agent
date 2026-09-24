# 코드 점검 목록

B1 코드(`guardian_ai/`)를 점검하며 찾은 결함. 2026-09-24 재현 확인.
고치면 체크하고 "해결" 칸에 날짜·테스트 이름을 적는다.

| # | 결함 | 심각도 | 지금 드러나는가 | 고칠 시점 | 해결 |
| --- | --- | --- | --- | --- | --- |
| 1 | alert 모드에서 재난 7종 중 3종이 엉뚱한 agent로 감 | 높음 | 예 (스텁 단계부터) | B2 (manager 교체) | - |
| 2 | 대화마다 초기화돼야 할 값이 다음 질문으로 넘어감 | 높음 | 아니요 (checkpointer를 붙이면 드러남) | B2 (`/chat`) | - |
| 3 | 다듬기를 다시 할 때 실패 사유(`polish_feedback`)가 전달되지 않음 | 중간 | 아니요 (스텁은 항상 통과) | B5 (polish 구현) | - |
| 4 | 대화 저장 시 Pydantic 타입 역직렬화 경고 | 낮음 (지금은 경고만) | checkpointer를 붙이면 드러남 | B2 | - |

---

## 1. alert 모드 라우팅 오류

- [ ] 수정
- [ ] 테스트 추가

**위치**: `graph.py:101-103` (`manager`)

**원인**: 재난 종류가 침수·호우인지 아닌지만 보고, 아니면 모두 강풍·태풍 agent로 보낸다.

**재현 결과**

| 경고 종류 | 선택된 agent | 맞는가 |
| --- | --- | --- |
| 산사태 | 강풍·태풍 + 위치·경로 | ❌ 산사태 agent여야 함 |
| 호우, 침수 | 강수·침수 + 위치·경로 | ✅ |
| 강풍, 태풍 | 강풍·태풍 + 위치·경로 | ✅ |
| 미세먼지, 자외선 | 강풍·태풍 + 위치·경로 | ❌ 생활안전 agent여야 함 |

**영향**
- 산사태 경고가 오면 산사태 위험지역을 조회하지 않은 채 바람 정보로 경고 메시지를 만든다.
- 미세먼지·자외선 경고에도 대피 경로를 붙여 과잉 경고가 된다.

**수정 방향**
- 재난 종류와 agent를 잇는 표를 둔다: 산사태→산사태, 호우·침수→강수·침수, 강풍·태풍→강풍·태풍, 미세먼지·자외선→생활안전.
- 위치·경로 agent는 위험 수준이 경보(`WARNING`)이고 대피가 필요한 재난일 때만 붙인다. 생활안전 경고에는 붙이지 않는다.
- 테스트: 재난 7종 각각을 넣어 선택 결과를 확인한다.

---

## 2. 대화마다 초기화돼야 할 값이 넘어감

- [ ] 수정
- [ ] 테스트 추가

**위치**: `graph.py:111-116` (`manager` 반환값)

**원인**: 대화 기록을 이어 가려고 checkpointer를 쓰면 같은 대화 스레드의 state가 저장된다. 그런데 manager는 새 질문이 와도
`specialist_results`와 `checks`만 비우고, `retry_count`·`polish_retry_count`·`manager_feedback`은 이전 질문의 값을 그대로 둔다.

**재현 결과**: 같은 대화에서 질문 3개를 보내고, 매 질문마다 환각 검증이 한 번 실패한 뒤 통과하도록 했다.

| 턴 | 질문 | retry_count | 결과 |
| --- | --- | --- | --- |
| 1 | 비 와요? | 1 | 정상 |
| 2 | 태풍 와요? | 2 (이전 값을 이어서 셈) | 정상 (재시도 한도를 다 씀) |
| 3 | 미세먼지 어때요? | 2 | **fallback** ("정확한 정보를 확인하지 못했습니다…") |

또 2턴에서 manager는 재시도가 아닌 첫 호출인데도 `manager_feedback`에 1턴의 "[hallucination] 수위 불일치"가 남아 있었다.

**영향**
- 대화가 길어질수록 재시도 기회가 줄다가 결국 모든 답변이 fallback이 된다.
- B2에서 LLM manager가 `manager_feedback`을 읽으면, 새 질문을 이전 실패에 대한 재시도로 잘못 알아듣는다.

**수정 방향**
- "새 질문의 시작"과 "재시도"를 구분한다. 예: `verdict == "retry"`일 때만 재시도로 본다.
- 새 질문이면 대화 단위 값을 모두 초기화한다:
  `retry_count`, `polish_retry_count`, `manager_feedback`, `polish_feedback`, `verdict`, `polish_verdict`, `verified_draft`, `polished`.
- `/chat` 입력에서 초기화할 수도 있지만, alert 모드 등 다른 진입점에서도 똑같이 해야 하므로 manager 안에서 처리하는 편이 안전하다.
- 테스트: 위 재현 시나리오를 그대로 추가한다. 지금 테스트는 매번 새 state로 실행하므로 이 문제를 잡지 못한다.

**재현 코드** (`코드/ai`에서 실행)

```python
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import StateGraph
from guardian_ai import graph as G
from guardian_ai.state import CheckResult, UserProfile

# build_graph가 checkpointer를 받지 않으므로 compile을 감싸서 주입
orig = StateGraph.compile
StateGraph.compile = lambda self, **kw: orig(self, checkpointer=MemorySaver())

seen = []
def fail_once_per_turn(state):
    q = state["question"]; seen.append(q)
    return {"checks": {"hallucination": CheckResult(ok=seen.count(q) > 1, feedback="수위 불일치")}}

app = G.build_graph({G.HALLUCINATION_CHECK: fail_once_per_turn})
cfg = {"configurable": {"thread_id": "u1"}}
for q in ["비 와요?", "태풍 와요?", "미세먼지 어때요?"]:
    r = app.invoke({"mode": "chat", "user": UserProfile(user_id="u1"), "question": q}, cfg)
    print(q, r["retry_count"], r["used_fallback"])   # 3번째가 fallback=True
```

---

## 3. 다듬기를 다시 할 때 실패 사유가 없음

- [ ] 수정
- [ ] 테스트 추가

**위치**: `graph.py:192-212` (`final_hallucination_check`, `final_check_gate`)

**원인**: state에 `polish_feedback`이 선언돼 있고(`state.py:202`) `polish`의 설명에도 "polish_feedback을 반영"한다고 적혀 있지만,
이 필드에 값을 쓰는 노드가 없다.

**영향**: 환각 재검증이 "수위 22cm를 30cm로 바꿨다"를 잡아내도 polish는 이유를 모른 채 다시 다듬으므로 같은 실수를 반복하기 쉽다.
한도가 1회라 무한 루프는 없고 다듬기 전 초안으로 돌아가지만, 다듬기 재시도가 사실상 쓸모없어진다.

**수정 방향**
- `final_hallucination_check`가 `CheckResult`처럼 실패 사유를 함께 반환한다.
- `final_check_gate`가 재시도를 결정할 때 그 사유를 `polish_feedback`에 기록한다. 루프 1의 `verify_gate` → `manager_feedback`과 같은 패턴.
- 테스트: 재검증을 한 번 실패시키고, 두 번째 polish 호출이 받은 `polish_feedback`이 비어 있지 않은지 확인한다.

---

## 4. 대화 저장 시 Pydantic 타입 역직렬화 경고

- [ ] 수정

**위치**: checkpointer 설정 (B2에서 만들 부분)

**원인**: checkpointer가 state를 저장·복원할 때 `UserProfile`, `SpecialistResult`, `CheckResult`, `ActionPlan`과 enum(`Phase`, `Specialist`,
`RiskLevel`)에 대해 다음 경고를 낸다.

```
Deserializing unregistered type guardian_ai.state.UserProfile from checkpoint. This will be blocked in a future version.
```

**영향**: 지금은 경고로 끝나지만 LangGraph가 업데이트되면 저장한 대화를 불러오지 못한다.

**수정 방향**: checkpointer를 만들 때 `guardian_ai.state`의 타입들을 허용 목록(`allowed_msgpack_modules`)에 등록한다.
등록 후 `LANGGRAPH_STRICT_MSGPACK=true`로 테스트를 돌려 막히는 타입이 없는지 확인한다.
