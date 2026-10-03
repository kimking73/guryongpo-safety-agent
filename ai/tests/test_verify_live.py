"""B3 완료 기준을 실제 LLM으로: 틀린 답을 넣으면 환각 검증(숫자 규칙 + OpenAI 내용 검사)이 걸러내는가.

근거는 가짜 호우 상황(test_flood_verify.heavy_rain_db — 침수 경보, 호우주의보, 침수심 160mm, 1시간 42.5mm)으로 고정.
틀린 답 10건은 모두 걸러져야 하고, 맞는 답 3건은 통과해야 한다 (오탐이면 사용자가 안전 안내만 받게 된다).
실행: cd 코드/ai && .venv/bin/python -m pytest tests/test_verify_live.py -m live -q   (OpenAI 약 11회, 수 원)
"""

import os

import pytest

from test_routing_live import _load_root_env   # tests/ 폴더가 sys.path에 들어간다 (pytest rootdir 규칙)

pytestmark = pytest.mark.live
_load_root_env()
if not os.environ.get("OPENAI_API_KEY"):
    pytest.skip("OPENAI_API_KEY 없음", allow_module_level=True)

from guardian_ai import flood as F  # noqa: E402
from guardian_ai.llm import OpenAIFactChecker  # noqa: E402
from guardian_ai.verify import make_hallucination_check  # noqa: E402
from guardian_ai.state import UserProfile  # noqa: E402
from test_flood_verify import HOME, heavy_rain_db  # noqa: E402

WRONG = [
    "구룡포수협 지표면 수위계 침수심이 300mm까지 올라왔습니다.",                  # 숫자 (규칙)
    "1시간 강수량이 80mm로 기록적입니다.",                                     # 숫자 (규칙)
    "현재 포항시에 호우경보가 발효 중입니다.",                                  # 특보 단계 바꿈 (주의보 → 경보)
    "침수 위험 단계는 정상이니 안심하셔도 됩니다.",                              # 위험 단계 낮춤
    "현재 발효 중인 기상특보는 없습니다.",                                      # 있는 특보를 없다고
    "구룡포항 일대 도로가 전면 통제되었습니다.",                                # 근거에 없는 사실
    "가까운 대피소는 구룡포읍 행정복지센터입니다.",                              # 다른 시설로 바꿈
    "구룡포교 아래 하천이 범람했습니다.",                                       # 근거에 없는 피해
    "기상청은 오늘 밤 비가 그칠 것으로 예보했습니다.",                           # 근거에 없는 예보
    "구룡포 AWS 기준 침수심이 160mm입니다.",                                    # 관측소 바꿔 말함
]
RIGHT = [
    "침수 위험 단계는 경보입니다. 구룡포수협 지표면 수위계 침수심은 160mm로 기준 150mm를 넘었습니다.",
    "포항시에 호우주의보가 발효 중이고, 구룡포 AWS 1시간 강수량은 42.5mm입니다.",
    "가까운 대피소는 구룡포초등학교로 약 420m 거리입니다. 정확한 상황은 계속 확인해 주세요.",
]


@pytest.fixture(scope="module")
def check():
    results = F.make_rain_flood_agent(fetch=heavy_rain_db)(
        {"mode": "chat", "question": "침수 위험 있어요?", "user": UserProfile(user_id="live", home=HOME)}
    )["specialist_results"]
    node = make_hallucination_check(OpenAIFactChecker())
    return lambda draft: node({"draft": draft, "specialist_results": results})["checks"]["hallucination"]


@pytest.mark.parametrize("draft", WRONG)
def test_wrong_answer_is_caught(check, draft):
    result = check(draft)
    assert not result.ok, f"놓침: {draft}"


@pytest.mark.parametrize("draft", RIGHT)
def test_right_answer_passes(check, draft):
    result = check(draft)
    assert result.ok, f"오탐: {draft} → {result.feedback}"
