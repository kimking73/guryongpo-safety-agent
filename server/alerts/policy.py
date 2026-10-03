"""경고 종류 판단 (2026-10-03 사용자 결정)

- 대피 확인(evacuation, 3버튼 + care.incidents):
    침수·호우·강풍·태풍·산사태가 경보(warning) 이상
    또는 재난문자에 대피 지시가 있고 '구룡포'를 언급 → 구룡포읍 안 사용자 전체
- 일반 경고(alert): 그 밖의 주의(advisory) 이상 — 위 5종의 주의, 미세먼지·초미세먼지·자외선·풍랑 등
- 관심(watch)·정상(normal) 은 경고하지 않음
- 침수·호우는 둘 중 하나라도 대피 확인이면 사용자에게 1건으로 묶어 보냄 (EVAC_GROUPS)
"""
from __future__ import annotations

import re
from typing import Literal, Optional

from risk.levels import LEVEL_NUM

Kind = Literal["evacuation", "alert"]

EVAC_HAZARDS = {"flood", "heavy_rain", "strong_wind", "typhoon", "landslide"}
# 함께 발효되는 일이 많아 대피 확인을 1건으로 묶는 재난 (앞쪽이 같은 단계일 때 우선) — 2026-10-03 결정
EVAC_GROUPS = [("flood", "heavy_rain")]
EVAC_MIN_LEVEL = "warning"
ALERT_MIN_LEVEL = "advisory"


def classify(hazard: str, level: str) -> Optional[Kind]:
    n = LEVEL_NUM.get(level, 0)
    if hazard in EVAC_HAZARDS and n >= LEVEL_NUM[EVAC_MIN_LEVEL]:
        return "evacuation"
    if n >= LEVEL_NUM[ALERT_MIN_LEVEL]:
        return "alert"
    return None


# 재난문자 대피 지시 — '대피소', '대피하시기', '대피 바랍니다', '대피명령', '대피 권고' 등.
# '대피 요령'·'대피로 확인'처럼 행동요령만 알리는 문구는 제외
EVAC_PATTERN = re.compile(r"대피\s*소|대피\s*하|대피\s*바랍|대피\s*명령|대피\s*권고|대피\s*지시|대피\s*하십|즉시\s*대피|긴급\s*대피")
AREA_WORD = "구룡포"

# 재난문자 분류(원문) → hazard (disaster_messages.hazard 가 비어 있을 때)
CATEGORY_HAZARD = {"호우": "heavy_rain", "태풍": "typhoon", "산사태": "landslide", "강풍": "strong_wind",
                   "홍수": "flood", "침수": "flood", "풍랑": "high_seas", "해일": "flood"}
MESSAGE_DEFAULT_HAZARD = "heavy_rain"


def is_evac_message(text: Optional[str]) -> bool:
    t = text or ""
    return AREA_WORD in t and bool(EVAC_PATTERN.search(t))


def message_hazard(hazard: Optional[str], category: Optional[str], text: Optional[str]) -> str:
    if hazard:
        return hazard
    for word, hz in CATEGORY_HAZARD.items():
        if word in (category or "") or word in (text or ""):
            return hz
    return MESSAGE_DEFAULT_HAZARD
