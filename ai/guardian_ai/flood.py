"""강수·침수 agent (B3).

순서: ① 코드가 DB에서 데이터를 모은다 (tools.py) → ② 코드가 쓸 수 있는 숫자를 근거(Evidence)로 만든다
      → ③ LLM은 그 근거만 보고 문장을 쓴다 (FloodWriter) → 환각 검증(verify.py)이 근거와 대조한다.
LLM이 실패하면 template_summary()가 근거 숫자를 그대로 넣은 정해진 문장으로 답한다 (답변이 끊기지 않게).
판정은 A의 판정 엔진(risk_assessments)을 그대로 따른다 — AI가 위험 단계를 새로 정하지 않는다.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from . import tools as T
from .db import Fetch
from .state import Evidence, GuardianState, Location, RiskLevel, Specialist, SpecialistResult

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))

# 위치를 모를 때 기준점: 구룡포읍 중심 (A의 risk/levels.py GURYONGPO_CENTER와 같은 값)
GURYONGPO_CENTER = Location(lat=35.9858, lon=129.5481, label="구룡포읍 중심")
# 이 반경 안의 위험 판정을 본다 (A의 침수 판정 반경이 100~500m)
RISK_RADIUS_M = 500
FLOOD_HAZARDS = ("flood", "heavy_rain")
WARNING_HAZARDS = ("heavy_rain", "typhoon")
LEVEL_KO = {"normal": "정상", "watch": "관심", "advisory": "주의", "warning": "경보", "critical": "위험"}
HAZARD_KO = {"flood": "침수", "heavy_rain": "호우", "typhoon": "태풍"}
METRIC_KO = {"flood_depth": "침수심", "river_level": "하천 수위", "manhole_level": "맨홀 수위",
             "rain_15m": "15분 강수량", "rain_1h": "1시간 강수량", "rain_12h": "12시간 강수량", "rain_day": "오늘 강수량"}
# 근거로 남길 관측소 수 (가까운 순). 너무 많으면 LLM이 헷갈린다
MAX_WATER_STATIONS = 4
STATUS_KO = {"planned": "예비특보", "active": "발효 중", "lifted": "해제"}


@dataclass
class FloodData:
    location: Location
    location_known: bool
    risk: dict[str, Any]
    water: dict[str, Any]
    rain: dict[str, Any]
    warnings: dict[str, Any]
    messages: dict[str, Any]
    shelters: dict[str, Any] | None = None
    level: RiskLevel = RiskLevel.NORMAL
    evidence: list[Evidence] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)   # 못 읽었거나 오래된 데이터 (답변에 밝힌다)


def pick_location(state: GuardianState) -> tuple[Location, bool]:
    """현재 위치 → 집 → 구룡포읍 중심 순. 두 번째 값은 사용자 위치를 알았는지.

    label은 항상 채운다 ("현재 위치"/"집"/사용자가 붙인 이름) — 근거 목록의 '기준 위치'와 답변 작성기에 같은 이름을 쓰기 위해.
    """
    loc = state.get("current_location")
    if loc:
        return loc.model_copy(update={"label": loc.label or "현재 위치"}), True
    user = state.get("user")
    if user is not None and user.home:
        return user.home.model_copy(update={"label": user.home.label or "집"}), True
    return GURYONGPO_CENTER, False


def location_text(d: "FloodData") -> str:
    """답변과 근거에 쓰는 기준 위치 이름. 위치를 모르면 그렇다고 밝힌다."""
    return d.location.label if d.location_known else "구룡포읍 중심(위치 정보 없음)"


def _ts(iso: str | None) -> datetime | None:
    return datetime.fromisoformat(iso) if iso else None


def collect(location: Location, location_known: bool, fetch: Fetch | None = None) -> FloodData:
    lat, lon = location.lat, location.lon
    risk = T.get_risk_at(lat, lon, radius_m=RISK_RADIUS_M, fetch=fetch)
    if not risk["available"]:
        # DB에 닿지 않으면 나머지도 같은 이유로 실패한다 → 조회마다 접속 제한 시간(3초)을 기다리지 않고 바로 넘어간다
        down = {**risk, "source": "db"}
        d = FloodData(location=location, location_known=location_known, risk=risk,
                      water=down, rain=down, warnings=down, messages=down)
    else:
        d = FloodData(
            location=location, location_known=location_known, risk=risk,
            water=T.get_observations("water_level", lat, lon, fetch=fetch),
            rain=T.get_observations("rain", lat, lon, fetch=fetch),
            warnings=T.get_weather_warnings(fetch=fetch),
            messages=T.get_disaster_messages(fetch=fetch),
        )
    flood_items = [i for i in d.risk.get("items", []) if i["hazard"] in FLOOD_HAZARDS]
    if flood_items:
        d.level = max((RiskLevel(i["level"]) for i in flood_items), key=lambda lv: lv.rank)
    # 주의 이상이면 가까운 대피소를 같이 (침수 지정 대피소가 데이터에 없어 종류를 거르지 않는다)
    if d.level.rank >= RiskLevel.ADVISORY.rank:
        d.shelters = T.get_facilities("shelter", lat, lon, limit=2, fetch=fetch)
    d.evidence, d.unavailable = build_evidence(d)
    return d


def build_evidence(d: FloodData) -> tuple[list[Evidence], list[str]]:
    """답변에 쓸 수 있는 사실을 근거 목록으로. 이 목록에 없는 숫자는 환각 검증에서 걸린다."""
    ev: list[Evidence] = []
    missing: list[str] = []

    # 기준 위치 — 아래 판정·거리는 모두 이 위치 기준. 답변 작성기에도 같은 이름을 준다.
    # (빠져 있으면 검증기가 "집"을 근거 없는 말로 보고 재시도를 일으켰다 — 2026-10-01 지연 측정에서 발견)
    ev.append(Evidence(source="request", key="기준 위치", value=location_text(d)))

    # 위험 판정 (A의 판정 엔진)
    if not d.risk.get("available"):
        missing.append("위험 판정")
    else:
        if d.risk.get("data_stale"):
            missing.append("위험 판정(30분 넘게 갱신 안 됨)")
        flood_items = [i for i in d.risk["items"] if i["hazard"] in FLOOD_HAZARDS]
        for i in flood_items:
            ev.append(Evidence(source="risk_assessments", key=f"{HAZARD_KO[i['hazard']]} 위험 단계",
                               value=LEVEL_KO[i["level"]], observed_at=_ts(i["observed_at"])))
            if i.get("reason"):
                ev.append(Evidence(source="risk_assessments", key=f"{HAZARD_KO[i['hazard']]} 판정 근거",
                                   value=i["reason"], observed_at=_ts(i["observed_at"])))
            if i["distance_m"] == 0:
                ev.append(Evidence(source="risk_assessments", key=f"{HAZARD_KO[i['hazard']]} 위험 영역",
                                   value="기준 위치가 영역 안"))
            else:
                ev.append(Evidence(source="risk_assessments", key=f"{HAZARD_KO[i['hazard']]} 위험 영역까지 거리",
                                   value=i["distance_m"], unit="m"))
        if not flood_items:
            ev.append(Evidence(source="risk_assessments", key="침수·호우 위험 단계", value="정상",
                               observed_at=_ts(d.risk.get("assessed_at"))))

    # 수위 (가까운 관측소부터, 오래된 값은 근거에서 뺀다)
    if not d.water.get("available"):
        missing.append("수위 관측")
    else:
        fresh = [i for i in d.water["items"] if not i["stale"]]
        if len(fresh) < len(d.water["items"]):
            missing.append("일부 수위계(2시간 넘은 값)")
        for i in fresh[:MAX_WATER_STATIONS]:
            name = i["station"].replace("_", " ")
            ev.append(Evidence(source="observations", key=f"{name} {METRIC_KO.get(i['metric'], i['metric'])}",
                               value=i["value"], unit=i["unit"], observed_at=_ts(i["observed_at"])))
            if i["level_label"]:
                ev.append(Evidence(source="observations", key=f"{name} 등급", value=i["level_label"]))
            ev.append(Evidence(source="observations", key=f"{name}까지 거리", value=i["distance_m"], unit="m"))

    # 강수 — 기상청 AWS(구룡포) 누적값 + 포항 DT 강우량계
    if not d.rain.get("available"):
        missing.append("강수 관측")
    else:
        seen: set[tuple[str, str]] = set()
        for i in d.rain["items"]:
            if i["stale"] or (i["station"], i["metric"]) in seen:
                continue
            if i["station_kind"] == "weather" and not i["station"].endswith("AWS") and i["metric"] != "rain_1h":
                continue
            seen.add((i["station"], i["metric"]))
            ev.append(Evidence(source="observations", key=f"{i['station']} {METRIC_KO.get(i['metric'], i['metric'])}",
                               value=i["value"], unit=i["unit"], observed_at=_ts(i["observed_at"])))

    # 기상특보 (호우·태풍)
    if not d.warnings.get("available"):
        missing.append("기상특보")
    else:
        related = [w for w in d.warnings["items"] if w["hazard"] in WARNING_HAZARDS]
        for w in related:
            ev.append(Evidence(source="weather_warnings", key=f"{w['region']} 특보",
                               value=f"{w['headline']} ({STATUS_KO[w['status']]})", observed_at=_ts(w["issued_at"])))
        if not related:
            ev.append(Evidence(source="weather_warnings", key="호우·태풍 특보", value="없음"))

    # 재난문자 (최근 6시간, 호우·침수 관련만)
    if d.messages.get("available"):
        for m in d.messages["items"]:
            if m["hazard"] in (*FLOOD_HAZARDS, None) and any(k in (m["text"] or "") for k in ("호우", "침수", "비", "하천")):
                ev.append(Evidence(source="disaster_messages", key=f"재난문자({m['sender']})", value=m["text"],
                                   observed_at=_ts(m["sent_at"])))

    # 대피소 (주의 이상일 때만)
    if d.shelters is not None:
        if not d.shelters.get("available"):
            missing.append("대피소")
        for s in d.shelters.get("items", []):
            ev.append(Evidence(source="shelters", key="가까운 대피소", value=s["name"]))
            ev.append(Evidence(source="shelters", key=f"{s['name']}까지 거리", value=s["distance_m"], unit="m"))
    return ev, missing


def evidence_lines(evidence: list[Evidence]) -> str:
    """LLM 프롬프트·검증용 근거 표기: "- 키: 값 단위 (HH:MM 관측)"."""
    lines = []
    for e in evidence:
        when = f" ({e.observed_at.astimezone(KST):%H:%M} 기준)" if e.observed_at else ""
        lines.append(f"- {e.key}: {_fmt(e.value)}{e.unit or ''}{when}")
    return "\n".join(lines)


def _fmt(v: Any) -> str:
    """230.0 → "230" (답변에 "230.0 mm"처럼 나오지 않게)."""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def template_summary(d: FloodData) -> str:
    """LLM 없이 근거 숫자를 그대로 넣은 문장. LLM 실패·시간 초과 때 쓴다."""
    parts = [f"{location_text(d)} 기준 침수·호우 위험 단계는 '{LEVEL_KO[d.level.value]}'입니다."]
    depth = next((e for e in d.evidence if e.key.endswith(("침수심", "하천 수위")) and e.source == "observations"), None)
    if depth:
        parts.append(f"가장 가까운 {depth.key}는 {_fmt(depth.value)}{depth.unit or ''}입니다.")
    rain = next((e for e in d.evidence if e.key.endswith("1시간 강수량")), None)
    if rain:
        parts.append(f"{rain.key}은 {_fmt(rain.value)}{rain.unit or ''}입니다.")
    warn = [e for e in d.evidence if e.source == "weather_warnings" and e.value != "없음"]
    if warn:
        parts.append("특보: " + ", ".join(str(e.value) for e in warn) + ".")
    shelter = next((e for e in d.evidence if e.key == "가까운 대피소"), None)
    if shelter:
        dist = next((e for e in d.evidence if e.key == f"{shelter.value}까지 거리"), None)
        parts.append(f"가까운 대피소는 {shelter.value}" + (f"({_fmt(dist.value)}m)" if dist else "") + "입니다.")
    if d.unavailable:
        parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
    return " ".join(parts)


# 문장 작성기의 형태: (질문, 근거 표기, 데이터, 재시도 사유) → 답변 조각. 실패하면 예외.
Writer = Callable[[str, str, FloodData, str], str]


def make_rain_flood_agent(writer: Writer | None = None, fetch: Fetch | None = None):
    """강수·침수 agent 노드. writer가 없거나 실패하면 template_summary를 쓴다.

    서비스는 llm.OpenAIWriter를 넣는다 (service.py). 테스트는 fetch에 가짜 DB를 넣는다.
    """
    def rain_flood_agent(state: GuardianState) -> dict:
        location, known = pick_location(state)
        data = collect(location, known, fetch=fetch)
        # 사용자 기억(지난 대화에서 사용자가 말한 사실)도 근거로 — 답변이 "무릎이 불편하시니"라고 써도 검증이 오탐하지 않게.
        # 재난 수치가 아니라 사람에 대한 정보다 (memory.py).
        data.evidence += [Evidence(source="user_memory", key="사용자 기억", value=m)
                          for m in state.get("user_memory") or []]
        summary, how = None, "템플릿"
        if writer is not None:
            try:
                summary, how = writer(state.get("question") or "", evidence_lines(data.evidence), data,
                                      state.get("manager_feedback") or ""), "LLM"
            except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                logger.warning("침수 agent 문장 작성 실패 → 템플릿 (%s: %s)", type(e).__name__, e)
        summary = summary or template_summary(data)
        logger.info("침수 agent [%s] 단계=%s 근거=%d 확인불가=%s", how, data.level.value, len(data.evidence),
                    data.unavailable or "-")
        return {"specialist_results": [SpecialistResult(
            agent=Specialist.RAIN_FLOOD, summary=summary, risk_level=data.level, evidence=data.evidence)]}

    return rain_flood_agent
