"""OpenAI 사용량·예상 비용 기록과 한도 경고 (2026-10-01).

OpenAI 응답마다 토큰 수(usage)를 받아 모델 단가로 비용을 계산해 파일에 누적한다.
월 예산(OPENAI_BUDGET_KRW, 기본 20만 원)의 50%·80%·100%를 처음 넘을 때 WARNING 로그를 남긴다.
경고만 하고 호출을 막지는 않는다 (사용자 결정). 현황은 GET /api/ai/usage.

한계: 이 서버가 부른 것만 센다. 같은 키를 다른 곳(맥 로컬·VM·키 주인)에서도 쓰면 각자 따로 센다.
      실제 청구액은 키 주인의 OpenAI 대시보드가 기준이다. 환율·단가는 아래 상수로 추정한다.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))

# 모델별 단가 (USD / 100만 토큰): (입력, 캐시된 입력, 출력). OpenAI 공식 모델 페이지 2026-10-01 기준.
# 추론 모델의 생각 토큰은 출력 토큰에 포함되어 청구된다.
PRICES_USD_PER_1M: dict[str, tuple[float, float, float]] = {
    "gpt-6-luna": (0.1, 0.01, 0.5),
    "gpt-6.1-sol": (2.0, 2.0, 10.0),   # 캐시 단가 미확인 → 입력 단가로 (많게 잡음)
    "gpt-6-astra": (10.0, 10.0, 50.0),
}
# 표에 없는 모델은 비싼 쪽(Astra)으로 계산해 경고가 늦지 않게 한다
UNKNOWN_MODEL_PRICE = PRICES_USD_PER_1M["gpt-6-astra"]
USD_KRW = 1400                       # 추정 환율. 경고용이라 대략이면 된다
DEFAULT_BUDGET_KRW = 200_000
WARN_RATIOS = (0.5, 0.8, 1.0)
# 컨테이너에서는 /srv/data (compose의 ai-data 볼륨) → 재시작해도 남는다
DEFAULT_PATH = Path(__file__).resolve().parents[1] / "data" / "openai_usage.json"


def _month(now: datetime | None = None) -> str:
    return (now or datetime.now(KST)).strftime("%Y-%m")


def cost_usd(model: str, input_tokens: int, cached_tokens: int, output_tokens: int) -> float:
    p_in, p_cached, p_out = PRICES_USD_PER_1M.get(model, UNKNOWN_MODEL_PRICE)
    fresh = max(0, input_tokens - cached_tokens)
    return (fresh * p_in + cached_tokens * p_cached + output_tokens * p_out) / 1_000_000


class UsageTracker:
    """호출마다 record()로 누적한다. 여러 요청이 동시에 와도 안전하도록 잠금을 쓴다. 달이 바뀌면 새로 센다."""

    def __init__(self, path: Path | str | None = None, budget_krw: int | None = None):
        self.path = Path(path) if path else DEFAULT_PATH
        self.budget_krw = budget_krw or int(os.environ.get("OPENAI_BUDGET_KRW") or DEFAULT_BUDGET_KRW)
        self._lock = threading.Lock()

    def _load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            data = {}
        if data.get("month") != _month():
            data = {"month": _month(), "calls": 0, "input_tokens": 0, "cached_tokens": 0,
                    "output_tokens": 0, "cost_usd": 0.0, "by_model": {}, "warned": []}
        return data

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.path)   # 쓰는 도중 꺼져도 파일이 깨지지 않게

    def record(self, model: str, usage: Any) -> float:
        """OpenAI 응답의 usage를 누적하고 이번 호출의 예상 비용(USD)을 돌려준다. 기록 실패는 답변을 막지 않는다."""
        if usage is None:
            return 0.0
        inp = int(getattr(usage, "input_tokens", 0) or 0)
        out = int(getattr(usage, "output_tokens", 0) or 0)
        details = getattr(usage, "input_tokens_details", None)
        cached = int(getattr(details, "cached_tokens", 0) or 0)
        cost = cost_usd(model, inp, cached, out)
        try:
            with self._lock:
                data = self._load()
                data["calls"] += 1
                data["input_tokens"] += inp
                data["cached_tokens"] += cached
                data["output_tokens"] += out
                data["cost_usd"] += cost
                data["by_model"][model] = data["by_model"].get(model, 0) + 1
                self._warn(data)
                self._save(data)
        except OSError:
            logger.exception("OpenAI 사용량 기록 실패")
        return cost

    def _warn(self, data: dict[str, Any]) -> None:
        spent = data["cost_usd"] * USD_KRW
        for ratio in WARN_RATIOS:
            if spent >= self.budget_krw * ratio and ratio not in data["warned"]:
                data["warned"].append(ratio)
                logger.warning("OpenAI 사용량 경고: %s 예상 비용 약 %s원 — 월 한도 %s원의 %d%% 도달 (호출 %d회)",
                               data["month"], f"{spent:,.0f}", f"{self.budget_krw:,}", int(ratio * 100), data["calls"])

    def summary(self) -> dict[str, Any]:
        with self._lock:
            data = self._load()
        spent = data["cost_usd"] * USD_KRW
        return {
            "month": data["month"], "calls": data["calls"], "by_model": data["by_model"],
            "input_tokens": data["input_tokens"], "cached_tokens": data["cached_tokens"],
            "output_tokens": data["output_tokens"],
            "cost_usd": round(data["cost_usd"], 4), "cost_krw": round(spent),
            "budget_krw": self.budget_krw, "used_pct": round(100 * spent / self.budget_krw, 2),
            "avg_krw_per_call": round(spent / data["calls"], 2) if data["calls"] else None,
            "warned_pct": [int(r * 100) for r in data["warned"]],
            "note": "이 서버가 부른 것만 추정. 실제 청구액은 OpenAI 대시보드 기준",
        }


_default: UsageTracker | None = None


def get_tracker() -> UsageTracker:
    """서버 전체가 공유하는 기록기."""
    global _default
    if _default is None:
        _default = UsageTracker()
    return _default
