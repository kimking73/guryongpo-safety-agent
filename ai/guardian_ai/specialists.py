"""산사태 · 강풍태풍 · 생활안전 agent (B4).

침수 agent(flood.py)와 같은 순서: ① 코드가 DB에서 데이터를 모은다 → ② 쓸 수 있는 사실만 근거(Evidence)로
→ ③ LLM은 근거만 보고 문장을 쓴다(llm.OpenAISpecialistWriter) → 환각 검증이 대조. LLM이 실패하면 템플릿 문장.
위험 단계는 A의 판정 엔진(risk_assessments)을 그대로 따른다 — AI가 새로 정하지 않는다.
행동요령은 여기서 쓰지 않는다 — 행동 권고(action.py)가 원문으로 따로 만든다.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable

from . import tools as T
from .db import Fetch
from .flood import LEVEL_KO, RISK_RADIUS_M, _fmt, _ts, location_text, pick_location
from .state import Evidence, GuardianState, Location, RiskLevel, Specialist, SpecialistResult

logger = logging.getLogger(__name__)

HAZARD_KO = {"landslide": "산사태", "heavy_rain": "호우", "strong_wind": "강풍", "typhoon": "태풍",
             "high_seas": "풍랑", "uv": "자외선"}
STATUS_KO = {"planned": "예비특보", "active": "발효 중", "lifted": "해제"}
# 산사태 취약지역을 찾는 반경 (m)
ZONE_RADIUS_M = 1000
FISHER_WORDS = ("어업", "어선", "선박", "선장", "어부", "양식", "수산")


@dataclass
class Collected:
    """agent 하나가 모은 것. 작성기(LLM)와 템플릿이 같은 근거를 본다."""
    location: Location
    location_known: bool
    level: RiskLevel = RiskLevel.NORMAL
    evidence: list[Evidence] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)   # 못 읽었거나 오래된 데이터 (답변에 밝힌다)
    facts: dict[str, Any] = field(default_factory=dict)     # 템플릿용 핵심 값


# (질문, 근거 표기, 모은 것, 재시도 사유) → 답변 조각. 실패하면 예외
Writer = Callable[[str, str, Collected, str], str]


def _max_level(items: list[dict[str, Any]]) -> RiskLevel:
    return max((RiskLevel(i["level"]) for i in items), key=lambda lv: lv.rank, default=RiskLevel.NORMAL)


def _risk_evidence(d: Collected, risk: dict[str, Any], hazards: tuple[str, ...], label: str,
                   primary: tuple[str, ...] | None = None) -> list[dict[str, Any]]:
    """판정 엔진 항목 → 근거. 주 재난(primary, 기본 hazards 전부) 판정이 없으면 '{label} 위험 단계: 정상' 한 줄.
    (산사태는 호우 판정만 있고 산사태 판정이 없을 때도 '산사태 정상'을 밝혀야 한다 — 2026-10-03 실측) 반환: 해당 항목들"""
    if not risk.get("available"):
        d.unavailable.append("위험 판정")
        return []
    if risk.get("data_stale"):
        d.unavailable.append("위험 판정(30분 넘게 갱신 안 됨)")
    items = [i for i in risk["items"] if i["hazard"] in hazards]
    for i in items:
        name = HAZARD_KO.get(i["hazard"], i["hazard"])
        d.evidence.append(Evidence(source="risk_assessments", key=f"{name} 위험 단계", value=LEVEL_KO[i["level"]],
                                   observed_at=_ts(i.get("observed_at"))))
        if i.get("reason"):
            d.evidence.append(Evidence(source="risk_assessments", key=f"{name} 판정 근거", value=i["reason"]))
    if not any(i["hazard"] in (primary or hazards) for i in items):
        d.evidence.append(Evidence(source="risk_assessments", key=f"{label} 위험 단계", value="정상",
                                   observed_at=_ts(risk.get("assessed_at"))))
    return items


def _nearest_fresh(obs: dict[str, Any], metric: str) -> dict[str, Any] | None:
    return next((i for i in obs.get("items", []) if i["metric"] == metric and not i["stale"]), None)


def _warning_evidence(d: Collected, warnings: dict[str, Any], hazards: tuple[str, ...], label: str) -> list[dict[str, Any]]:
    if not warnings.get("available"):
        d.unavailable.append("기상특보")
        return []
    related = [w for w in warnings["items"] if w["hazard"] in hazards]
    for w in related:
        d.evidence.append(Evidence(source="weather_warnings", key=f"{w['region']} 특보",
                                   value=f"{w['headline']} ({STATUS_KO[w['status']]})", observed_at=_ts(w["issued_at"])))
    if not related:
        d.evidence.append(Evidence(source="weather_warnings", key=f"{label} 특보", value="없음"))
    return related


def _start(state: GuardianState) -> Collected:
    location, known = pick_location(state)
    d = Collected(location=location, location_known=known)
    d.evidence.append(Evidence(source="request", key="기준 위치", value=location_text(d)))
    return d


# --- 산사태 -------------------------------------------------------------------

def collect_landslide(state: GuardianState, fetch: Fetch | None = None) -> Collected:
    d = _start(state)
    lat, lon = d.location.lat, d.location.lon
    risk = T.get_risk_at(lat, lon, radius_m=RISK_RADIUS_M, fetch=fetch)
    items = _risk_evidence(d, risk, ("landslide", "heavy_rain"), "산사태", primary=("landslide",))
    d.level = _max_level([i for i in items if i["hazard"] == "landslide"])

    zones = T.get_hazard_zones(lat, lon, radius_m=ZONE_RADIUS_M, kind="landslide", limit=3, fetch=fetch)
    if not zones.get("available"):
        d.unavailable.append("산사태 취약지역")
    else:
        inside = next((z for z in zones["items"] if z["contains_point"]), None)
        if inside:
            d.evidence.append(Evidence(source="hazard_zones", key="산사태 취약지역",
                                       value=f"기준 위치가 취약지역 안 ({inside['name']}{', ' + inside['grade'] if inside['grade'] else ''})"))
            d.facts["zone"] = "안"
        elif zones["items"]:
            z = zones["items"][0]
            d.evidence.append(Evidence(source="hazard_zones", key="가장 가까운 산사태 취약지역", value=z["name"]))
            d.evidence.append(Evidence(source="hazard_zones", key="가장 가까운 산사태 취약지역까지 거리",
                                       value=z["distance_m"], unit="m"))
            d.facts["zone"] = z["distance_m"]
        else:
            d.evidence.append(Evidence(source="hazard_zones", key=f"반경 {ZONE_RADIUS_M}m 안 산사태 취약지역", value="없음"))

    rain = T.get_observations("rain", lat, lon, fetch=fetch) if risk.get("available") else {"available": False}
    if not rain.get("available"):
        d.unavailable.append("강수 관측")
    else:
        for metric, name in (("rain_1h", "1시간 강수량"), ("rain_12h", "12시간 강수량"), ("rain_day", "오늘 강수량")):
            i = _nearest_fresh(rain, metric)
            if i:
                d.evidence.append(Evidence(source="observations", key=f"{i['station']} {name}", value=i["value"],
                                           unit=i["unit"], observed_at=_ts(i["observed_at"])))
                d.facts.setdefault("rain", (f"{i['station']} {name}", i["value"], i["unit"]))
    return d


def landslide_template(d: Collected) -> str:
    parts = [f"{location_text(d)} 기준 산사태 위험 단계는 '{LEVEL_KO[d.level.value]}'입니다."]
    zone = d.facts.get("zone")
    if zone == "안":
        parts.append("기준 위치가 산사태 취약지역 안입니다.")
    elif zone is not None:
        parts.append(f"가장 가까운 산사태 취약지역까지 {zone}m입니다.")
    if "rain" in d.facts:
        key, value, unit = d.facts["rain"]
        parts.append(f"{key}은 {_fmt(value)}{unit or ''}입니다.")
    if d.unavailable:
        parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
    return " ".join(parts)


# --- 강풍·태풍 ------------------------------------------------------------------

def _is_fisher(state: GuardianState) -> bool:
    user = state.get("user")
    occupation = (user.occupation or "") if user is not None else ""
    return any(w in occupation for w in FISHER_WORDS)


def collect_wind_typhoon(state: GuardianState, fetch: Fetch | None = None) -> Collected:
    d = _start(state)
    lat, lon = d.location.lat, d.location.lon
    # 어업인이면 풍랑을 앞에 둔다 (선박·어구 대비가 먼저)
    hazards = ("high_seas", "typhoon", "strong_wind") if _is_fisher(state) else ("typhoon", "strong_wind", "high_seas")
    d.facts["fisher"] = _is_fisher(state)
    risk = T.get_risk_at(lat, lon, radius_m=RISK_RADIUS_M, fetch=fetch)
    items = _risk_evidence(d, risk, hazards, "강풍·태풍")
    items.sort(key=lambda i: hazards.index(i["hazard"]))
    d.level = _max_level(items)
    d.facts["items"] = [(HAZARD_KO[i["hazard"]], LEVEL_KO[i["level"]]) for i in items]

    if risk.get("available"):
        wind = T.get_observations("wind", lat, lon, fetch=fetch)
        warnings = T.get_weather_warnings(fetch=fetch)
    else:
        wind = warnings = {"available": False}
    if not wind.get("available"):
        d.unavailable.append("바람 관측")
    else:
        for metric, name in (("wind_speed", "풍속"), ("wind_gust", "순간최대풍속"), ("wind_dir", "풍향")):
            i = _nearest_fresh(wind, metric)
            if i:
                d.evidence.append(Evidence(source="observations", key=f"{i['station']} {name}", value=i["value"],
                                           unit=i["unit"], observed_at=_ts(i["observed_at"])))
                if metric != "wind_dir":
                    d.facts.setdefault("wind", []).append((f"{i['station']} {name}", i["value"], i["unit"]))
    related = _warning_evidence(d, warnings, hazards, "강풍·태풍·풍랑")
    d.facts["warnings"] = [w["headline"] for w in related if w["status"] != "lifted"]
    return d


def wind_typhoon_template(d: Collected) -> str:
    parts = [f"{location_text(d)} 기준 강풍·태풍 위험 단계는 '{LEVEL_KO[d.level.value]}'입니다."]
    if d.facts.get("items"):
        parts.append("판정: " + ", ".join(f"{h} {lv}" for h, lv in d.facts["items"]) + ".")
    for key, value, unit in d.facts.get("wind", [])[:2]:
        parts.append(f"{key}은 {_fmt(value)}{unit or ''}입니다.")
    if d.facts.get("warnings"):
        parts.append("특보: " + ", ".join(d.facts["warnings"]) + ".")
    if d.unavailable:
        parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
    return " ".join(parts)


# --- 생활안전 ------------------------------------------------------------------

# 자외선 등급 → 판정 단계 (A의 risk_rules uv와 같은 대응: 낮음 정상, 보통 관심, 높음 주의, 매우높음 경보, 위험 위험)
UV_LEVEL = {"낮음": RiskLevel.NORMAL, "보통": RiskLevel.WATCH, "높음": RiskLevel.ADVISORY,
            "매우높음": RiskLevel.WARNING, "위험": RiskLevel.CRITICAL}


def collect_life_safety(state: GuardianState, fetch: Fetch | None = None) -> Collected:
    d = _start(state)
    life = T.get_life_safety(d.location.lat, d.location.lon, fetch=fetch)
    if not life.get("available"):
        d.unavailable.append("생활안전 관측")
        return d
    uv = life.get("uv")
    if uv is None or uv.get("stale"):
        d.unavailable.append("자외선")
    else:
        d.evidence += [Evidence(source="observations", key=f"{uv['station']} 자외선 지수", value=uv["value"],
                                observed_at=_ts(uv["observed_at"])),
                       Evidence(source="observations", key="자외선 등급", value=uv["grade"])]
        d.level = UV_LEVEL.get(uv["grade"], RiskLevel.NORMAL)
        d.facts["uv"] = (uv["value"], uv["grade"])
    for key, name in (("pm10", "미세먼지"), ("pm25", "초미세먼지")):
        item = life.get(key)
        if item is None or item.get("stale"):
            d.unavailable.append(f"{name}(아직 수집하지 않음)" if item is None else name)
        else:
            d.evidence += [Evidence(source="observations", key=f"{item['station']} {name}", value=item["value"],
                                    unit=item["unit"], observed_at=_ts(item["observed_at"])),
                           Evidence(source="observations", key=f"{name} 등급", value=item["grade"])]
    return d


def life_safety_template(d: Collected) -> str:
    parts = [f"{location_text(d)} 기준 생활안전 정보입니다."]
    if "uv" in d.facts:
        value, grade = d.facts["uv"]
        parts.append(f"자외선 지수는 {_fmt(value)}로 '{grade}' 등급입니다.")
    if d.unavailable:
        parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
    return " ".join(parts)


# --- 노드 만들기 -----------------------------------------------------------------

def make_specialist(agent: Specialist, collect: Callable[..., Collected], template: Callable[[Collected], str],
                    writer: Writer | None = None, fetch: Fetch | None = None):
    """전문 agent 노드. writer(LLM)가 없거나 실패하면 template. 사용자 기억도 근거로 넣는다 (flood.py와 같은 이유)."""
    def node(state: GuardianState) -> dict:
        d = collect(state, fetch=fetch)
        d.evidence += [Evidence(source="user_memory", key="사용자 기억", value=m) for m in state.get("user_memory") or []]
        # 확인할 수 없는 정보도 근거로 — 작성기가 "미세먼지는 아직 수집하지 않음"이라고 쓰면 검증기도 그 사실을 알아야 한다
        # (2026-10-03 실측: 빠져 있어 자외선 질문이 검증 3회 실패 → 안전 안내로 끝남)
        d.evidence += [Evidence(source="data_status", key="확인할 수 없는 정보", value=u) for u in d.unavailable]
        summary, how = None, "템플릿"
        if writer is not None:
            try:
                from .flood import evidence_lines
                summary, how = writer(state.get("question") or "", evidence_lines(d.evidence), d,
                                      state.get("manager_feedback") or ""), "LLM"
            except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                logger.warning("%s 문장 작성 실패 → 템플릿 (%s: %s)", agent.value, type(e).__name__, e)
        summary = summary or template(d)
        logger.info("%s [%s] 단계=%s 근거=%d 확인불가=%s", agent.value, how, d.level.value, len(d.evidence),
                    d.unavailable or "-")
        return {"specialist_results": [SpecialistResult(agent=agent, summary=summary, risk_level=d.level,
                                                        evidence=d.evidence)]}
    node.__name__ = agent.value
    return node


def make_landslide_agent(writer: Writer | None = None, fetch: Fetch | None = None):
    return make_specialist(Specialist.LANDSLIDE, collect_landslide, landslide_template, writer, fetch)


def make_wind_typhoon_agent(writer: Writer | None = None, fetch: Fetch | None = None):
    return make_specialist(Specialist.WIND_TYPHOON, collect_wind_typhoon, wind_typhoon_template, writer, fetch)


def make_life_safety_agent(writer: Writer | None = None, fetch: Fetch | None = None):
    return make_specialist(Specialist.LIFE_SAFETY, collect_life_safety, life_safety_template, writer, fetch)


__all__ = ["make_landslide_agent", "make_wind_typhoon_agent", "make_life_safety_agent", "make_specialist"]
