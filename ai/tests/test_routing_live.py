"""B2 완료 기준: 질문 유형별로 올바른 agent가 호출되는가 (실제 Gemini 호출).

실행: cd 코드/ai && .venv/bin/python -m pytest -m live -q
키는 환경 변수 또는 루트 .env의 GEMINI_API_KEY를 쓴다.
"""

import os
from pathlib import Path

import pytest

from guardian_ai.state import Specialist as A, UserProfile

pytestmark = pytest.mark.live

ROOT_ENV = Path(__file__).resolve().parents[2] / ".env"


def _load_root_env() -> None:
    """루트 .env의 KEY=VALUE를 환경 변수에 채운다 (이미 있으면 그대로)."""
    if not ROOT_ENV.exists():
        return
    for line in ROOT_ENV.read_text(encoding="utf-8").splitlines():
        line = line.split(" #", 1)[0].strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


_load_root_env()
if not os.environ.get("GEMINI_API_KEY"):
    pytest.skip("GEMINI_API_KEY 없음", allow_module_level=True)

import time  # noqa: E402

import httpx  # noqa: E402
from google.genai import errors as genai_errors  # noqa: E402

from guardian_ai.llm import GeminiClassifier  # noqa: E402  키 확인 뒤 import

# (질문, 반드시 포함할 agent, 포함하면 안 되는 agent)
CASES = [
    ("비 오는데 지금 걸어서 집에 가도 되나요?", {A.RAIN_FLOOD, A.LOCATION_ROUTE}, {A.LIFE_SAFETY}),
    ("구룡포항 수위가 지금 얼마예요?", {A.RAIN_FLOOD}, {A.LIFE_SAFETY, A.LANDSLIDE}),
    ("뒷산 근처 사는데 산사태 위험 있어요?", {A.LANDSLIDE}, {A.LIFE_SAFETY}),
    ("태풍 온다는데 배는 어떻게 묶어둬야 해요?", {A.WIND_TYPHOON}, {A.LIFE_SAFETY}),
    ("오늘 바람 많이 불어요?", {A.WIND_TYPHOON}, {A.LANDSLIDE, A.LIFE_SAFETY}),
    ("오늘 미세먼지 어때요? 산책해도 돼요?", {A.LIFE_SAFETY}, {A.LANDSLIDE, A.WIND_TYPHOON}),
    ("자외선 지수 알려줘", {A.LIFE_SAFETY}, {A.RAIN_FLOOD, A.LANDSLIDE}),
    ("가장 가까운 대피소가 어디예요?", {A.LOCATION_ROUTE}, {A.LIFE_SAFETY}),
    ("지금 뭘 해야 하나요?", {A.LANDSLIDE, A.RAIN_FLOOD, A.WIND_TYPHOON}, {A.LIFE_SAFETY}),
    ("안녕하세요", set(), set(A)),
    ("이 앱은 어떻게 쓰는 거예요?", set(), set(A)),
    ("집중호우에 산 밑에 사는데 대피해야 하나요?", {A.RAIN_FLOOD, A.LANDSLIDE, A.LOCATION_ROUTE}, {A.LIFE_SAFETY}),
]


MIN_INTERVAL_S = 60 / int(os.environ.get("GEMINI_LIVE_RPM", "5"))   # 무료 등급: 모델당 분당 5회


class PacedClassifier:
    """분당 호출 한도를 지키고, 일시적 오류(429 한도·503 과부하)는 기다렸다 다시 시도한다."""

    def __init__(self):
        self.inner, self.next_at = GeminiClassifier(), 0.0

    @property
    def last(self):
        return self.inner.last

    def __call__(self, state):
        for attempt in range(4):
            time.sleep(max(0.0, self.next_at - time.monotonic()))
            self.next_at = time.monotonic() + MIN_INTERVAL_S
            try:
                return self.inner(state)
            except httpx.TimeoutException:
                if attempt == 3:
                    raise
            except genai_errors.APIError as e:
                if e.code not in (429, 503) or attempt == 3:
                    raise
                time.sleep(60 if e.code == 429 else 5)


@pytest.fixture(scope="module")
def classify():
    return PacedClassifier()


@pytest.mark.parametrize("question, must, must_not", CASES, ids=[c[0] for c in CASES])
def test_routes_question_to_expected_agents(classify, question, must, must_not):
    got = set(classify({"mode": "chat", "user": UserProfile(user_id="live"), "question": question}))
    reason = classify.last.reason if classify.last else ""
    assert must <= got, f"빠짐 {must - got} / 선택 {got} / 이유: {reason}"
    assert not (got & must_not), f"불필요 {got & must_not} / 선택 {got} / 이유: {reason}"


def test_follow_up_uses_history(classify):
    got = set(classify({
        "mode": "chat", "user": UserProfile(user_id="live"), "question": "거기까지 가는 길은 안전해요?",
        "history": [
            {"role": "user", "content": "가장 가까운 대피소가 어디예요?"},
            {"role": "assistant", "content": "구룡포 실내체육관입니다."},
        ],
    }))
    assert A.LOCATION_ROUTE in got
