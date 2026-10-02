"""위치·경로 agent (B4 일부): "어디로 피해야 해?", "대피소까지 몇 분?" 같은 질문.

침수 agent(flood.py)와 같은 순서: ① 코드가 데이터를 모은다 (가까운 대피소 + 갈 만한지, 실제 경로)
→ ② 쓸 수 있는 사실만 근거(Evidence)로 → ③ LLM은 근거만 보고 문장을 쓴다 → 환각 검증이 근거와 대조.
LLM이 실패하면 template_summary()가 근거를 그대로 넣은 정해진 문장으로 답한다.

대피소 고르기 규칙은 앱과 같다 (tools.get_safe_shelters): 발효 중인 침수·산사태 영역 안의 대피소와,
침수 중 지하 시설은 뺀다. 갈 만한 곳이 없으면 가장 가까운 곳을 경고와 함께 안내한다.
경로는 사용자 정보로 성인/노약자를 고른다 (tools.route_profile).
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from typing import Any, Callable

from . import tools as T
from .db import Fetch
from .flood import evidence_lines, location_text, pick_location
from .state import Evidence, GuardianState, Location, Specialist, SpecialistResult

logger = logging.getLogger(__name__)

# 대피 후보로 볼 대피소 수 (가까운 순). 위험 영역 안을 빼고도 고를 곳이 남도록 넉넉히
CANDIDATES = 8
PROFILE_KO = {"adult": "성인 경로(가장 빠른 길)", "elderly": "노약자 경로(급경사를 피한 길)"}
TYPE_KO = {"tsunami": "지진해일 대피장소", "civil_defense": "민방위 대피시설", "earthquake": "지진 옥외대피장소",
           "shelter": "임시주거시설"}


@dataclass
class LocationData:
    location: Location
    location_known: bool
    shelters: dict[str, Any]
    profile: str = "adult"
    chosen: dict[str, Any] | None = None
    route: dict[str, Any] | None = None
    evidence: list[Evidence] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)


def collect(state: GuardianState, fetch: Fetch | None = None, route_client=None) -> LocationData:
    location, known = pick_location(state)
    user = state.get("user")
    d = LocationData(location=location, location_known=known,
                     shelters=T.get_safe_shelters(location.lat, location.lon, limit=CANDIDATES, fetch=fetch),
                     profile=T.route_profile(user) if user is not None else "adult")
    items = d.shelters.get("items", [])
    d.chosen = next((s for s in items if s["safe"]), None) or (items[0] if items else None)
    if d.chosen is not None:
        d.route = T.request_route((location.lat, location.lon), (d.chosen["lat"], d.chosen["lon"]),
                                  profile=d.profile, client=route_client)
    d.evidence, d.unavailable = build_evidence(d)
    return d


def build_evidence(d: LocationData) -> tuple[list[Evidence], list[str]]:
    ev = [Evidence(source="request", key="기준 위치", value=location_text(d))]
    missing: list[str] = []
    if not d.shelters.get("available"):
        missing.append("대피소")
        return ev, missing
    if d.chosen is None:
        missing.append("대피소(근처에 없음)")
        return ev, missing

    s = d.chosen
    kinds = ", ".join(TYPE_KO.get(k, k) for k in s["shelter_types"]) or "대피소"
    ev += [Evidence(source="shelters", key="안내 대피소", value=s["name"]),
           Evidence(source="shelters", key=f"{s['name']} 종류", value=f"{kinds} · {'실내' if s['is_indoor'] else '실외'}")]
    if not s["safe"]:
        ev.append(Evidence(source="shelters", key="주의",
                           value=f"근처에 위험 영역 밖 대피소가 없어 가장 가까운 곳을 안내함 ({s['excluded_reason']})"))
    skipped = [x for x in d.shelters["items"] if not x["safe"] and x["distance_m"] < s["distance_m"]]
    for x in skipped[:3]:
        ev.append(Evidence(source="shelters", key=f"제외한 더 가까운 대피소: {x['name']}", value=x["excluded_reason"]))

    r = d.route or {}
    if not r.get("available"):
        missing.append(f"경로 안내({r.get('reason') or '경로 서버 응답 없음'})")
        ev.append(Evidence(source="shelters", key=f"{s['name']}까지 직선거리", value=s["distance_m"], unit="m"))
        return ev, missing
    ev += [Evidence(source="route", key="경로 종류", value=PROFILE_KO.get(r["profile"], r["profile"])),
           Evidence(source="route", key="경로 거리", value=r["distance_m"], unit="m"),
           Evidence(source="route", key="도보 소요 시간", value=math.ceil(r["duration_s"] / 60), unit="분")]
    if r.get("avoided"):
        ev.append(Evidence(source="route", key="경로가 피한 위험 영역 수", value=len(r["avoided"]), unit="곳"))
    if r.get("still_inside"):
        ev.append(Evidence(source="route", key="다른 길이 없어 지나는 위험 영역 수", value=len(r["still_inside"]), unit="곳"))
    if r.get("hazards_ok") is False:
        missing.append("경로 위 위험 영역(위험 정보를 읽지 못해 회피 없이 계산함)")
    return ev, missing


def template_summary(d: LocationData) -> str:
    """LLM 없이 근거를 그대로 넣은 문장. LLM 실패·시간 초과 때 쓴다."""
    if d.chosen is None:
        return f"{location_text(d)} 근처 대피소 정보를 지금 확인할 수 없습니다."
    s, r = d.chosen, d.route or {}
    parts = [f"{location_text(d)}에서 안내할 대피소는 {s['name']}입니다."]
    if not s["safe"]:
        parts.append(f"근처에 위험 영역 밖 대피소가 없어 가장 가까운 곳을 안내합니다({s['excluded_reason']}).")
    if r.get("available"):
        parts.append(f"{PROFILE_KO.get(r['profile'], r['profile'])}로 {r['distance_m']}m, 도보 약 {math.ceil(r['duration_s'] / 60)}분입니다.")
        if r.get("still_inside"):
            parts.append(f"다른 길이 없어 위험 영역 {len(r['still_inside'])}곳을 지나니 주의하세요.")
    else:
        parts.append(f"경로 안내는 지금 할 수 없습니다. 직선거리는 {s['distance_m']}m입니다.")
    if d.unavailable:
        parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
    return " ".join(parts)


# (질문, 근거 표기, 데이터, 재시도 사유) → 답변 조각. 실패하면 예외
Writer = Callable[[str, str, LocationData, str], str]


def make_location_route_agent(writer: Writer | None = None, fetch: Fetch | None = None, route_client=None):
    """위치·경로 agent 노드. writer가 없거나 실패하면 template_summary. 서비스는 llm.OpenAILocationWriter를 넣는다."""
    def location_route_agent(state: GuardianState) -> dict:
        data = collect(state, fetch=fetch, route_client=route_client)
        data.evidence += [Evidence(source="user_memory", key="사용자 기억", value=m)
                          for m in state.get("user_memory") or []]
        summary, how = None, "템플릿"
        if writer is not None and data.chosen is not None:
            try:
                summary, how = writer(state.get("question") or "", evidence_lines(data.evidence), data,
                                      state.get("manager_feedback") or ""), "LLM"
            except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                logger.warning("위치·경로 agent 문장 작성 실패 → 템플릿 (%s: %s)", type(e).__name__, e)
        summary = summary or template_summary(data)
        logger.info("위치·경로 agent [%s] 대피소=%s 안전=%s 경로=%s", how, (data.chosen or {}).get("name"),
                    (data.chosen or {}).get("safe"), (data.route or {}).get("available"))
        return {"specialist_results": [SpecialistResult(
            agent=Specialist.LOCATION_ROUTE, summary=summary, evidence=data.evidence,
            route={k: v for k, v in (data.route or {}).items() if k != "geometry"} or None)]}

    return location_route_agent
