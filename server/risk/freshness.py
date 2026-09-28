"""자료 신선도 규칙 — "표시는 최신값 + 경과 시간, 판단은 유효한 값만" 을 한 곳에서 관리

원칙 (2026-09-28 팀 결정)
  1. 표시(대시보드·Agent 설명): 수집이 실패해도 **가장 최근에 성공한 값**을 보여 준다. 단 측정 시각과
     "N분 전 자료"를 함께 표시하고, 유효 시간을 넘었으면 stale=true → 앱·Agent 는 "오래된 자료" 로 안내
  2. 판단(위험 판정·경고): 유효 시간 안의 값만 사용. 없으면 FALLBACK 순서로 다른 출처를 쓰고,
     그것도 없으면 '안전(normal)'이 아니라 **판단 불가(unknown)** — 오래된 '정상' 값으로 안전하다고 말하지 않기 위함
  3. 호우·강풍 판단(A4)은 judge_source() 로 출처를 고른 뒤 risk_rules 기준을 적용한다 (아래 FALLBACK 참고)

유효 시간 근거: 수집 주기 × 3~4 (연속 3회 실패하면 무효) · 원천 갱신 주기
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

KST = timezone(timedelta(hours=9))

# (source_code, 판별자) → 유효 시간(분). 판별자는 station kind 또는 external_id 접두사
VALID_MIN: dict[tuple[str, str], int] = {
    ("pohang_dt", "manhole"): 40, ("pohang_dt", "road_flood"): 40,      # 10분 수집 (원천 약 1시간 갱신)
    ("pohang_dt", "river_level"): 40, ("pohang_dt", "rain_gauge"): 40,
    ("pohang_dt", "air"): 60, ("pohang_dt", "uv"): 90,                  # 원천 측정 시각 기준
    ("kma", "aws_"): 30,                                                # 구룡포 AWS 816, 10분 수집
    ("kma", "grid_"): 90,                                               # 초단기실황 격자, 매시 1회
}
DEFAULT_VALID_MIN = 60

# 호우·강풍 판단용 출처 우선순위 (A4). 앞에서부터 유효한 값이 있는 첫 출처를 사용
#   구룡포 AWS 실측 → 초단기실황 격자(읍 중심 → 항구). 순간풍속(wind_gust)은 AWS 에만 있음
FALLBACK: dict[str, list[tuple[str, str]]] = {
    "rain_1h":    [("kma", "aws_816"), ("pohang_dt", "5"), ("kma", "grid_105_94"), ("kma", "grid_106_94")],  # 5 = DT 강우량계
    "rain_12h":   [("kma", "aws_816")],                                  # 없으면 rain_1h 합산(RAIN_SUM_SQL)으로
    "wind_speed": [("kma", "aws_816"), ("kma", "grid_105_94"), ("kma", "grid_106_94")],
    "wind_gust":  [("kma", "aws_816")],                                  # 대체 출처 없음 → 평균풍속 기준만 판단
}


def valid_minutes(source_code: str, kind: Optional[str] = None, external_id: str = "") -> int:
    for (src, key), m in VALID_MIN.items():
        if src == source_code and (key == kind or (key.endswith("_") and external_id.startswith(key))):
            return m
    return DEFAULT_VALID_MIN


def _dt(t) -> Optional[datetime]:
    if t is None:
        return None
    return datetime.fromisoformat(t) if isinstance(t, str) else t


def age_minutes(observed_at, now: Optional[datetime] = None) -> Optional[int]:
    t = _dt(observed_at)
    return None if t is None else max(0, int(((now or datetime.now(KST)) - t).total_seconds() // 60))


def freshness(observed_at, source_code: str, kind: Optional[str] = None, external_id: str = "",
              now: Optional[datetime] = None) -> dict:
    """표시용: {age_min, valid_min, stale, label} — label 예) '14:20 측정 · 40분 전 자료'"""
    t, lim = _dt(observed_at), valid_minutes(source_code, kind, external_id)
    if t is None:
        return {"age_min": None, "valid_min": lim, "stale": True, "label": "자료 없음"}
    age = age_minutes(t, now)
    ago = "방금" if age < 1 else f"{age}분 전" if age < 120 else f"{age // 60}시간 전"
    return {"age_min": age, "valid_min": lim, "stale": age > lim,
            "label": f"{t.astimezone(KST):%H:%M} 기준 · {ago} 자료" + (" (오래된 자료)" if age > lim else "")}


def judge_source(metric: str, latest: Iterable[dict], now: Optional[datetime] = None) -> Optional[dict]:
    """판단용: FALLBACK 순서로 유효한 첫 관측값. 없으면 None → 호출 측은 level='unknown'(판단 불가)
    latest 행: {source_code, external_id, kind, metric, value, observed_at}"""
    rows = [r for r in latest if r["metric"] == metric]
    for src, ext in FALLBACK.get(metric, []):
        for r in rows:
            if r["source_code"] == src and r["external_id"] == ext:
                f = freshness(r["observed_at"], src, r.get("kind"), ext, now)
                if not f["stale"]:
                    return {**r, **f, "fallback_rank": FALLBACK[metric].index((src, ext))}
    return None
