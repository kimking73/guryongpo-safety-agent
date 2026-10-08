"""B13 방문 우선순위 — 방재단 대피 현황 명단 순서 (사용자 결정 2026-10-08)

규칙 (같은 입력이면 항상 같은 순서·근거):
  위험지역(대피 상황 영역) 안의 대상만 명단에 남긴다.
  1 도움 필요 + 장애 · 2 도움 필요 · 3 응답 없음 + 장애 · 4 응답 없음 · 5 대피 중 · 6 대피 완료
  장애 = 시각·청각·지체장애 (가구 사정 needs, 또는 가구 미등록 앱 사용자는 서버 프로필)
  같은 순위 안에서는 방재단원 위치에서 가까운 순, 위치가 없으면 오래 기다린 순, 그다음 id 순.
읽을 때마다 계산한다 — 상태가 바뀌면 다음 폴링(10초)에 순서가 바로 바뀐다. DB 칸(priority_score)에는 쓰지 않는다.
"""
from __future__ import annotations

import math
from typing import Optional

# 가구 사정(care.households.needs) 중 장애로 보는 것 → 화면 이름
DISABILITY_NEEDS = {"vision": "시각장애", "hearing": "청각장애",
                    "wheelchair": "휠체어", "bedridden": "와상", "mobility_limited": "보행 불편"}
TIER_LABEL = {1: "도움 요청", 2: "도움 요청", 3: "응답 없음", 4: "응답 없음", 5: "대피 중", 6: "대피 완료"}
TIER_FACTOR = {1: "need_help", 2: "need_help", 3: "no_response", 4: "no_response", 5: "evacuating", 6: "evacuated"}
# 근거 점수 (명세 PriorityReason.points) — 상태 + 장애 합이 순위 1~4 순서와 같다: 350 > 300 > 150 > 100.
# 거리·대기·영역 밖은 같은 순위 안 순서만 정하므로 0점
STATUS_POINTS = {"need_help": 300, "no_response": 100, "evacuating": 10, "evacuated": 0}
DISABILITY_POINTS = 50


def disabilities(t: dict) -> list[str]:
    """대상의 장애 이름 목록 (없으면 빈 목록). 가구는 needs, 앱 사용자는 프로필 칸(up_*)"""
    out = [DISABILITY_NEEDS[n] for n in DISABILITY_NEEDS if n in (t.get("needs") or [])]
    if t.get("kind") == "app_user":
        if t.get("up_vision"):
            out.append("시각장애")
        if t.get("up_hearing"):
            out.append("청각장애")
        if t.get("up_mobility") == "wheelchair":
            out.append("휠체어")
        elif t.get("up_walking") in ("limited", "unable"):
            out.append("보행 불편")
    return out


def _dis(t: dict) -> list[str]:
    """target_out 이 붙인 disabilities 가 있으면 그것, 없으면 계산"""
    return t["disabilities"] if "disabilities" in t else disabilities(t)


def tier(t: dict) -> int:
    disabled = bool(_dis(t))
    s = t.get("status")
    if s == "need_help":
        return 1 if disabled else 2
    if s == "no_response":
        return 3 if disabled else 4
    return 5 if s == "evacuating" else 6


def distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """두 (위도, 경도) 사이 거리 m (haversine)"""
    la1, lo1, la2, lo2 = map(math.radians, (*a, *b))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def rank(targets: list[dict], origin: Optional[tuple[float, float]] = None, keep_outside: bool = False) -> list[dict]:
    """명단 순서를 정해 priority_rank(1부터)·priority_score(높을수록 먼저)·priority_reasons 를 붙인다.
    in_area 가 False 인 대상(영역 밖으로 이동한 앱 사용자 등)은 뺀다 — keep_outside=True 면 남겨 맨 뒤로 (한 건 응답용)."""
    rows = []
    for t in targets:
        outside = t.get("in_area") is False
        if outside and not keep_outside:
            continue
        loc = t.get("location") or {}
        dist = (distance_m(origin, (loc["lat"], loc["lng"]))
                if origin and loc.get("lat") is not None and loc.get("lng") is not None else None)
        rows.append((t, tier(t), dist, outside))

    def key(x):
        t, tr, dist, outside = x
        near = dist if origin else -(t.get("minutes_since_alert") or 0)   # 가까운 순 / 오래 기다린 순
        return (outside, tr, near if near is not None else math.inf, str(t.get("id")))

    rows.sort(key=key)
    n = len(rows)
    for i, (t, tr, dist, outside) in enumerate(rows, 1):
        reasons = [{"factor": TIER_FACTOR[tr], "points": STATUS_POINTS[TIER_FACTOR[tr]], "label": TIER_LABEL[tr]}]
        dis = _dis(t)
        if dis and tr <= 4:
            reasons.append({"factor": "disability", "points": DISABILITY_POINTS, "label": "·".join(dict.fromkeys(dis))})
        if outside:
            reasons.append({"factor": "outside_area", "points": 0, "label": "위험지역 밖"})
        elif dist is not None:
            reasons.append({"factor": "distance", "points": 0,
                            "label": f"{dist / 1000:.1f}km" if dist >= 1000 else f"{round(dist)}m"})
        elif origin is None and tr <= 4:
            reasons.append({"factor": "waiting", "points": 0, "label": f"{t.get('minutes_since_alert') or 0}분째"})
        t["priority_rank"] = i
        t["priority_score"] = float(n - i + 1)
        t["priority_reasons"] = reasons
        t["priority_tier"] = tr
    return [t for t, *_ in rows]
