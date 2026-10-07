"""사용자 정보 추출기(실제 OpenAI, 결과는 서버 프로필로): 사용자가 자기에 대해 직접 말한 것만 고르고, 추측·재난 정보는 고르지 않는가.

실행: cd 코드/ai && .venv/bin/python -m pytest tests/test_memory_live.py -m live -q   (OpenAI 6회, 2원 이하)
"""

import os

import pytest

from test_routing_live import _load_root_env

pytestmark = pytest.mark.live
_load_root_env()
if not os.environ.get("OPENAI_API_KEY"):
    pytest.skip("OPENAI_API_KEY 없음", allow_module_level=True)

from guardian_ai.llm import OpenAIMemoryExtractor  # noqa: E402

ANSWER = "현재 침수 위험 단계는 경보입니다. 가까운 대피소는 구룡포초등학교(420m)입니다."


@pytest.fixture(scope="module")
def extract():
    return OpenAIMemoryExtractor()


def fields(update):
    return {f.field: f.value for f in update.facts}


@pytest.mark.parametrize("question, field, value", [
    ("저 무릎이 안 좋아서 지팡이 짚고 다녀요. 대피소 어디예요?", "walking_impaired", "true"),
    ("저는 72살인데 비 오면 어디로 가야 해요?", "age", "72"),
    ("어선을 갖고 있는데 태풍 오면 어떻게 해요?", "occupation", None),
])
def test_saves_what_user_says_about_themselves(extract, question, field, value):
    got = fields(extract(question, ANSWER, []))
    assert field in got, got
    if value:
        assert got[field].strip().lower() == value


@pytest.mark.parametrize("question", [
    "비가 와서 걷기 힘드네요. 대피소 어디예요?",       # 날씨 때문 → 보행 불편이 아님
    "구룡포항 수위가 160mm래요. 위험해요?",           # 재난 정보는 기억 금지
    "가장 가까운 대피소가 어디예요?",                  # 사용자 정보 없음
])
def test_does_not_save_guesses_or_disaster_data(extract, question):
    update = extract(question, ANSWER, [])
    assert "walking_impaired" not in fields(update), fields(update)
    assert not any("mm" in f.value or "수위" in f.value or "경보" in f.value for f in update.facts), fields(update)
