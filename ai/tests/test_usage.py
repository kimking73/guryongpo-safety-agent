"""OpenAI 사용량 기록·예산 경고 (usage.py)."""

import logging
from types import SimpleNamespace

from guardian_ai.llm import Classification, OpenAIClassifier
from guardian_ai.state import Specialist
from guardian_ai.usage import USD_KRW, UsageTracker, cost_usd


def usage(inp, out, cached=0):
    return SimpleNamespace(input_tokens=inp, output_tokens=out,
                           input_tokens_details=SimpleNamespace(cached_tokens=cached))


def test_cost_uses_model_price_and_cached_discount():
    # gpt-6-luna: 입력 0.1, 캐시 0.01, 출력 0.5 (USD / 100만 토큰)
    assert cost_usd("gpt-6-luna", 1_000_000, 0, 1_000_000) == 0.6
    assert cost_usd("gpt-6-luna", 1_000_000, 1_000_000, 0) == 0.01
    # 모르는 모델은 비싼 단가로 (경고가 늦지 않게)
    assert cost_usd("unknown", 1_000_000, 0, 0) > cost_usd("gpt-6-luna", 1_000_000, 0, 0)


def test_records_survive_restart(tmp_path):
    path = tmp_path / "u.json"
    UsageTracker(path, budget_krw=200_000).record("gpt-6-luna", usage(1000, 200))
    s = UsageTracker(path, budget_krw=200_000).summary()   # 새 기록기 = 재시작
    assert s["calls"] == 1 and s["input_tokens"] == 1000 and s["output_tokens"] == 200
    assert s["by_model"] == {"gpt-6-luna": 1}


def test_warns_once_per_threshold(tmp_path, caplog):
    # 한도 1,400원 = 1달러. 0.6달러씩 두 번 → 1.2달러: 50%(1회차)·80%·100%(2회차)
    t = UsageTracker(tmp_path / "u.json", budget_krw=USD_KRW)
    with caplog.at_level(logging.WARNING, logger="guardian_ai.usage"):
        t.record("gpt-6-luna", usage(1_000_000, 1_000_000))
        assert [r.getMessage().count("50%") for r in caplog.records] == [1]
        t.record("gpt-6-luna", usage(1_000_000, 1_000_000))
        t.record("gpt-6-luna", usage(10, 10))   # 이미 경고한 단계는 다시 경고하지 않는다
    msgs = [r.getMessage() for r in caplog.records]
    assert len(msgs) == 3 and "80%" in msgs[1] and "100%" in msgs[2]
    assert t.summary()["warned_pct"] == [50, 80, 100]


def test_classifier_records_usage(tmp_path):
    tracker = UsageTracker(tmp_path / "u.json")
    resp = SimpleNamespace(output_parsed=Classification(agents=[Specialist.RAIN_FLOOD], reason="비"),
                           output_text="...", usage=usage(500, 50))
    client = SimpleNamespace(responses=SimpleNamespace(parse=lambda **kw: resp))
    OpenAIClassifier(client=client, model="gpt-6-luna", tracker=tracker)({"mode": "chat", "question": "비 와요?"})
    assert tracker.summary()["calls"] == 1
