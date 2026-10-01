"""환각 검증 (B3): 답변 초안이 전문 agent가 남긴 근거(Evidence)와 맞는지 확인한다.

두 단계, 둘 다 통과해야 한다.
  ① 숫자 검사 (규칙, check_numbers): 초안의 측정값(단위가 붙은 숫자)이 근거에 있는지. 단위 변환·반올림은 허용.
     LLM을 쓰지 않으므로 빠르고, 같은 입력엔 늘 같은 결과.
  ② 내용 검사 (LLM, FactChecker): 숫자가 아닌 주장 — 특보 이름·위험 단계·"안전합니다" 같은 단정이 근거와 맞는지.
     LLM이 실패하면 ①의 결과만으로 판단하고 로그를 남긴다 (검증 장애로 답변을 막지 않는다).
실패하면 feedback에 무엇이 틀렸는지 적는다 → verify_gate가 관리자에게 넘겨 다시 쓰게 한다 (최대 2회, 그 뒤 안전 안내).
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Callable

from .state import CheckResult, Evidence, GuardianState

logger = logging.getLogger(__name__)

# 단위 → (차원, 기준 단위로 바꾸는 배수). 길이는 mm, 속도는 m/s 기준
UNITS: dict[str, tuple[str, float]] = {
    "mm": ("length", 1), "밀리미터": ("length", 1), "밀리": ("length", 1),
    "cm": ("length", 10), "센티미터": ("length", 10), "센티": ("length", 10),
    "km": ("length", 1_000_000), "킬로미터": ("length", 1_000_000),
    "m": ("length", 1000), "미터": ("length", 1000),
    "m/s": ("speed", 1), "km/h": ("speed", 1 / 3.6),
    "%": ("percent", 1), "퍼센트": ("percent", 1),
    "℃": ("temp", 1), "°C": ("temp", 1), "도": ("temp", 1),
    "hPa": ("pressure", 1),
    "㎍/㎥": ("conc", 1), "µg/m³": ("conc", 1), "μg/m³": ("conc", 1),
}
# 긴 단위를 먼저 맞춘다 (m/s가 m로, km/h가 km로 잘리지 않게)
_UNIT_RE = "|".join(re.escape(u) for u in sorted(UNITS, key=len, reverse=True))
# 숫자 + (공백) + 단위. 단위 뒤에 영문자가 붙으면(예: "mmHg") 다른 단위로 보고 건너뛴다
MEASURE_RE = re.compile(rf"(?<![\d.])(\d{{1,3}}(?:,\d{{3}})+|\d+(?:\.\d+)?)\s*({_UNIT_RE})(?![A-Za-z/])")


@dataclass(frozen=True)
class Measure:
    value: float           # 기준 단위로 바꾼 값
    dimension: str
    tolerance: float       # 기준 단위 기준 허용 오차 (표기 자릿수 반올림)
    text: str              # 원문 표기 (피드백용)


def _decimals(num: str) -> int:
    return len(num.split(".")[1]) if "." in num else 0


def extract_measures(text: str) -> list[Measure]:
    out = []
    for m in MEASURE_RE.finditer(text):
        num, unit = m.group(1), m.group(2)
        dim, factor = UNITS[unit]
        if unit == "도" and dim == "temp" and not re.search(r"(기온|온도|섭씨)", text[max(0, m.start() - 12):m.start()]):
            continue   # "30도 경사", "1도" 같은 각도·순서는 온도로 보지 않는다
        value = float(num.replace(",", ""))
        tol = 0.5 * 10 ** -_decimals(num) * factor     # "0.2m" → 반올림 오차 ±0.05m
        out.append(Measure(value * factor, dim, tol, m.group(0)))
    return out


def evidence_measures(evidence: list[Evidence]) -> list[Measure]:
    """근거의 숫자 값(단위 포함)과, 문장형 근거("침수심 160mm (기준 150mm)") 안의 숫자를 모두 모은다."""
    out = []
    for e in evidence:
        if isinstance(e.value, (int, float)) and not isinstance(e.value, bool) and e.unit in UNITS:
            dim, factor = UNITS[e.unit]
            out.append(Measure(float(e.value) * factor, dim, 0.0, f"{e.key} {e.value}{e.unit}"))
        elif isinstance(e.value, str):
            out.extend(extract_measures(e.value))
    return out


def check_numbers(draft: str, evidence: list[Evidence]) -> CheckResult:
    """초안의 측정값마다 같은 차원의 근거 값이 반올림 오차 안에 있어야 한다."""
    known = evidence_measures(evidence)
    unsupported = []
    for m in extract_measures(draft):
        ok = any(k.dimension == m.dimension and abs(k.value - m.value) <= m.tolerance + k.tolerance + 1e-9
                 for k in known)
        if not ok:
            unsupported.append(m.text)
    if unsupported:
        return CheckResult(ok=False, feedback="근거(DB)에 없는 수치: " + ", ".join(dict.fromkeys(unsupported))
                           + " — 근거 목록에 있는 값만 그대로 쓸 것")
    return CheckResult(ok=True)


# 내용 검사기의 형태: (초안, 근거 표기) → CheckResult. 실패하면 예외 (그때는 숫자 검사만으로 판단).
FactChecker = Callable[[str, str], CheckResult]


def make_hallucination_check(checker: FactChecker | None = None):
    """환각 검증 노드. checker가 없으면 숫자 검사만 한다 (테스트·LLM 없는 환경)."""
    from .flood import evidence_lines   # 근거 표기 형식을 침수 agent 프롬프트와 똑같이 맞춘다

    def hallucination_check(state: GuardianState) -> dict:
        draft = state.get("draft") or ""
        evidence = [e for r in state.get("specialist_results", []) for e in r.evidence]
        result = check_numbers(draft, evidence)
        how = "숫자"
        if result.ok and checker is not None and evidence:
            try:
                result, how = checker(draft, evidence_lines(evidence)), "숫자+내용"
            except Exception as e:  # noqa: BLE001
                logger.warning("내용 검사 실패 → 숫자 검사 결과만 사용 (%s: %s)", type(e).__name__, e)
        logger.info("환각 검증 [%s] %s %s", how, "통과" if result.ok else "실패", result.feedback)
        return {"checks": {"hallucination": result}}

    return hallucination_check
