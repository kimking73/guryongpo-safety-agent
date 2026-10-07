"""위치·경로 agent (B4 일부): "어디로 피해야 해?", "대피소까지 몇 분?", "구룡포항까지 어떻게 가?" 같은 질문.

목적지: 관리자가 질문에서 뽑은 destination_query가 있으면 그곳(등록 장소 → DB 시설 → 카카오 장소 검색, tools.find_place),
없거나 못 찾으면 가장 가까운 안전한 대피소. 목적지가 지금 위험 영역 안이면 가까운 안전한 대피소를 함께 근거로 넣는다.
경로(geometry 포함)는 SpecialistResult.route로 남겨 채팅 응답(service.ChatResponse.route)으로 앱 지도에 그린다.

침수 agent(flood.py)와 같은 순서: ① 코드가 데이터를 모은다 (가까운 대피소 + 갈 만한지, 실제 경로)
→ ② 쓸 수 있는 사실만 근거(Evidence)로 → ③ LLM은 근거만 보고 문장을 쓴다 → 환각 검증이 근거와 대조.
LLM이 실패하면 template_summary()가 근거를 그대로 넣은 정해진 문장으로 답한다.

대피소 고르기 규칙은 앱과 같다 (tools.get_safe_shelters): 발효 중인 침수·산사태 영역 안의 대피소와,
침수 중 지하 시설은 뺀다. 갈 만한 곳이 없으면 가장 가까운 곳을 경고와 함께 안내한다.
경로는 사용자 정보로 성인/노약자를 고른다 (tools.route_profile).

해상(B11, 2026-10-07): 경로는 경로 서버 /api/route/sea로 구한다 — 육지면 일반 경로와 같고, 바다 위면 가장 가까운
항구까지 바닷길(거리·방위) + 항구 육상 지점부터 도보 경로. 목적지를 말하지 않았으면 대피소를 항구 기준으로 다시 고른다
(바다 위 좌표에서 가까운 대피소가 아니라 배를 댄 뒤 가까운 곳). 해상 범위 밖(422)·해상 경로 장애는 일반 경로로 대신한다.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from typing import Any, Callable

from . import tools as T
from .db import Fetch
from .flood import RISK_TOPICS, evidence_lines, location_text, pick_location, strip_deferrals
from .state import Evidence, GuardianState, Location, Specialist, SpecialistResult

logger = logging.getLogger(__name__)

# 대피 후보로 볼 대피소 수 (가까운 순). 위험 영역 안을 빼고도 고를 곳이 남도록 넉넉히
CANDIDATES = 8
PROFILE_KO = {"adult": "성인 경로(가장 빠른 길)", "elderly": "노약자 경로(급경사를 피한 길)"}
SOURCE_KO = {"user": "등록 장소", "db": "대피소·의료시설 목록", "kakao": "카카오 장소 검색"}
TYPE_KO = {"tsunami": "지진해일 대피장소", "civil_defense": "민방위 대피시설", "earthquake": "지진 옥외대피장소",
           "shelter": "임시주거시설"}


@dataclass
class LocationData:
    location: Location
    location_known: bool
    shelters: dict[str, Any]
    profile: str = "adult"
    chosen: dict[str, Any] | None = None          # 안내할 대피소 (목적지가 없거나 못 찾았을 때, 또는 위험한 목적지의 대안)
    destination_query: str | None = None
    place: dict[str, Any] | None = None           # 찾은 목적지 (find_place 결과, available일 때만)
    place_missing: str | None = None              # 목적지를 못 찾은 이유
    place_hazard: str | None = None               # 목적지가 들어 있는 위험 영역 이름
    route: dict[str, Any] | None = None
    sea: dict[str, Any] | None = None             # 바다 위일 때 해상 구간 (경로 서버 /api/route/sea의 port·sea_leg)
    evidence: list[Evidence] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)


def collect(state: GuardianState, fetch: Fetch | None = None, route_client=None, place_client=None) -> LocationData:
    location, known = pick_location(state)
    user = state.get("user")
    d = LocationData(location=location, location_known=known,
                     shelters=T.get_safe_shelters(location.lat, location.lon, limit=CANDIDATES, fetch=fetch),
                     profile=T.route_profile(user) if user is not None else "adult",
                     destination_query=state.get("destination_query"))
    items = d.shelters.get("items", [])
    d.chosen = next((s for s in items if s["safe"]), None) or (items[0] if items else None)

    if d.destination_query:
        found = T.find_place(d.destination_query, user, fetch=fetch, client=place_client)
        if found.get("available") and not found.get("out_of_area"):
            d.place = found
            hz = T.hazards_at(found["lat"], found["lon"], fetch=fetch)
            d.place_hazard = hz.get("labels") if hz.get("available") else None
        elif found.get("out_of_area"):
            d.place_missing = f"'{found['name']}'은(는) 구룡포 밖이라 걸어서 안내할 수 없음"
        else:
            d.place_missing = found.get("reason") or "찾지 못함"

    target = route_target(d)
    if target is not None:
        _route(d, fetch, route_client)
    d.evidence, d.unavailable = build_evidence(d)
    return d


def _route(d: LocationData, fetch: Fetch | None, route_client) -> None:
    """해상 경로 서버로 바다 위인지 함께 본다. 바다 위가 아니거나 해상 경로를 못 쓰면 일반 경로."""
    origin, target = (d.location.lat, d.location.lon), route_target(d)
    sea = T.request_sea_route(origin, (target["lat"], target["lon"]), profile=d.profile, client=route_client)
    if not (sea.get("available") and sea.get("at_sea")):
        land = sea.get("land_route") if sea.get("available") else None
        d.route = {**land, "available": True} if land else \
            T.request_route(origin, (target["lat"], target["lon"]), profile=d.profile, client=route_client)
        return
    d.sea = {"port": sea["port"], "sea_leg": sea["sea_leg"]}
    if d.place is None:
        # 목적지를 말하지 않았으면 배를 댄 항구 기준으로 갈 만한 대피소를 다시 고른다
        lp = sea["port"]["land_point"]
        d.shelters = T.get_safe_shelters(lp["lat"], lp["lon"], limit=CANDIDATES, fetch=fetch)
        items = d.shelters.get("items", [])
        d.chosen = next((s for s in items if s["safe"]), None) or (items[0] if items else None)
        if d.chosen is None:
            d.route = {"available": False, "reason": "항구 근처 대피소를 찾지 못함"}
            return
        d.route = T.request_route((lp["lat"], lp["lon"]), (d.chosen["lat"], d.chosen["lon"]), profile=d.profile,
                                  client=route_client)
        return
    land = sea.get("land_route")
    d.route = {**land, "available": True} if land else \
        {"available": False, "reason": sea.get("land_route_error") or "항구에서 목적지까지 경로 없음"}


def route_target(d: LocationData) -> dict[str, Any] | None:
    """경로를 낼 곳: 목적지. 단 목적지가 위험 영역 안이고 안전한 대피소가 있으면 그 대피소 (위험한 곳으로 길을 그리지 않는다)."""
    if d.place is not None and not (d.place_hazard and d.chosen is not None and d.chosen["safe"]):
        return d.place
    return d.chosen


def route_info(d: LocationData) -> dict[str, Any] | None:
    """채팅 응답용 경로 (앱이 지도에 그린다). 경로를 못 구했으면 None."""
    target = route_target(d)
    r = d.route or {}
    if target is None or not r.get("available"):
        return None
    kind = d.place["kind"] if target is d.place else "shelter"
    info = {"destination": {"name": target["name"], "lat": target["lat"], "lon": target["lon"], "kind": kind},
            **{k: r.get(k) for k in ("profile", "distance_m", "duration_s", "avoided", "still_inside", "geometry")},
            "hazards_ok": r.get("hazards_ok", True)}
    if d.sea is not None:
        port, leg = d.sea["port"], d.sea["sea_leg"]
        # 앱이 바닷길(path)과 항구 → 목적지 도보 경로(geometry)를 함께 그린다
        info["sea"] = {"port_name": port["name"], "berth": port["berth"], "land_point": port["land_point"],
                       **{k: leg.get(k) for k in ("distance_m", "straight_m", "bearing_deg", "bearing_label", "path",
                                                  "path_found")}}
    return info


def build_evidence(d: LocationData) -> tuple[list[Evidence], list[str]]:
    ev = [Evidence(source="request", key="기준 위치", value=location_text(d))]
    missing: list[str] = []
    if d.sea is not None:
        _sea_evidence(d.sea, ev, missing)
    if d.place is not None:
        return _place_evidence(d, ev, missing)
    if d.destination_query:
        ev.append(Evidence(source="request", key="요청한 목적지",
                           value=f"{d.destination_query} — {d.place_missing}. 대신 가장 가까운 안전한 대피소를 안내함"))
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
    # 대피소 종류(지진해일 등)만 보고 검증기가 "호우 대피 장소라는 근거 없음"으로 막았다 (2026-10-03 live) → 고른 기준을 근거로
    if s["safe"]:
        ev.append(Evidence(source="shelters", key="대피소 선정 기준",
                           value="지정 대피소 중 현재 침수·산사태 위험 영역 밖에서 가장 가까운 곳 (재난 종류와 관계없이 대피 장소로 안내)"))
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
    _route_evidence(r, ev, missing)
    return ev, missing


def _sea_evidence(sea: dict[str, Any], ev: list[Evidence], missing: list[str]) -> None:
    port, leg = sea["port"], sea["sea_leg"]
    ev += [Evidence(source="route", key="현재 위치", value="해상(바다 위)"),
           Evidence(source="route", key="배를 댈 가장 가까운 항구", value=port["name"]),
           Evidence(source="route", key=f"{port['name']} 방향", value=leg["bearing_label"])]
    if leg.get("path_found", True):
        ev.append(Evidence(source="route", key=f"{port['name']}까지 바닷길 거리", value=leg["distance_m"], unit="m"))
        if not leg.get("direct", True):
            ev.append(Evidence(source="route", key="바닷길", value="곶·방파제를 돌아 들어가야 함 (지도의 바닷길을 따라감)"))
    else:
        ev.append(Evidence(source="route", key=f"{port['name']}까지 직선거리", value=leg["straight_m"], unit="m"))
        missing.append("바닷길(육지·방파제를 피하는 길을 찾지 못해 방향만 안내)")
    alts = [a["name"] for a in leg.get("alternatives") or []]
    if alts:
        ev.append(Evidence(source="route", key="다른 가까운 항구", value=", ".join(alts)))
    ev.append(Evidence(source="route", key="육상 경로 출발점", value=f"{port['name']} (배에서 내린 뒤)"))


def _route_evidence(r: dict[str, Any], ev: list[Evidence], missing: list[str]) -> None:
    ev += [Evidence(source="route", key="경로 종류", value=PROFILE_KO.get(r["profile"], r["profile"])),
           Evidence(source="route", key="경로 거리", value=r["distance_m"], unit="m"),
           Evidence(source="route", key="도보 소요 시간", value=math.ceil(r["duration_s"] / 60), unit="분")]
    if r.get("avoided"):
        ev.append(Evidence(source="route", key="경로가 피한 위험 영역 수", value=len(r["avoided"]), unit="곳"))
    if r.get("still_inside"):
        ev.append(Evidence(source="route", key="다른 길이 없어 지나는 위험 영역 수", value=len(r["still_inside"]), unit="곳"))
    if r.get("hazards_ok") is False:
        missing.append("경로 위 위험 영역(위험 정보를 읽지 못해 회피 없이 계산함)")


def _place_evidence(d: LocationData, ev: list[Evidence], missing: list[str]) -> tuple[list[Evidence], list[str]]:
    """목적지를 찾았을 때: 목적지·출처, 목적지 위험, 경로, (위험하면) 대신 갈 대피소."""
    p = d.place
    ev.append(Evidence(source=p["source"], key="목적지", value=p["name"]))
    ev.append(Evidence(source=p["source"], key="목적지를 찾은 곳", value=SOURCE_KO.get(p["source"], p["source"])))
    if p.get("address"):
        ev.append(Evidence(source=p["source"], key="목적지 주소", value=p["address"]))
    if d.place_hazard:
        ev.append(Evidence(source="risk_assessments", key="목적지 위험", value=f"목적지가 지금 위험 영역 안({d.place_hazard})"))
        s = d.chosen
        if s is not None and s["safe"]:
            ev.append(Evidence(source="shelters", key="대신 갈 수 있는 가까운 대피소", value=s["name"]))
    target = route_target(d)
    if target is not None:
        ev.append(Evidence(source="route", key="경로 도착지", value=target["name"]))
    r = d.route or {}
    if not r.get("available"):
        missing.append(f"경로 안내({r.get('reason') or '경로 서버 응답 없음'})")
        return ev, missing
    _route_evidence(r, ev, missing)
    return ev, missing


def template_summary(d: LocationData) -> str:
    """LLM 없이 근거를 그대로 넣은 문장. LLM 실패·시간 초과 때 쓴다."""
    text = _template_body(d)
    if d.sea is None:
        return text
    port, leg = d.sea["port"], d.sea["sea_leg"]
    how = f"바닷길로 {leg['distance_m']}m" if leg.get("path_found", True) else f"직선거리 {leg['straight_m']}m(바닷길은 찾지 못함)"
    return (f"지금 바다 위에 계십니다. {leg['bearing_label']}의 가장 가까운 항구 {port['name']}까지 {how}이며, "
            f"배를 댄 뒤 걸어서 이동하세요. " + text)


def _template_body(d: LocationData) -> str:
    if d.place is not None:
        p, r, target = d.place, d.route or {}, route_target(d)
        parts = [f"{location_text(d)}에서 {p['name']}까지 안내합니다."]
        if d.place_hazard:
            parts.append(f"{p['name']}은(는) 지금 위험 영역 안({d.place_hazard})이라 가지 않는 것이 좋습니다.")
            if target is not p:
                parts.append(f"대신 가까운 대피소 {target['name']}로 가세요.")
        if r.get("available") and target is not None:
            parts.append(f"{target['name']}까지 {PROFILE_KO.get(r['profile'], r['profile'])}로 {r['distance_m']}m, 도보 약 {math.ceil(r['duration_s'] / 60)}분입니다.")
            if r.get("still_inside"):
                parts.append(f"다른 길이 없어 위험 영역 {len(r['still_inside'])}곳을 지나니 주의하세요.")
        else:
            parts.append("경로 안내는 지금 할 수 없습니다.")
        if d.unavailable:
            parts.append("지금 확인할 수 없는 정보: " + ", ".join(d.unavailable) + ".")
        return " ".join(parts)
    if d.chosen is None:
        return f"{location_text(d)} 근처 대피소 정보를 지금 확인할 수 없습니다."
    s, r = d.chosen, d.route or {}
    parts = [f"{location_text(d)}에서 안내할 대피소는 {s['name']}입니다."]
    if d.destination_query:
        parts.insert(0, f"'{d.destination_query}'은(는) {d.place_missing}이라, 가장 가까운 안전한 대피소를 안내합니다.")
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


def make_location_route_agent(writer: Writer | None = None, fetch: Fetch | None = None, route_client=None,
                              place_client=None):
    """위치·경로 agent 노드. writer가 없거나 실패하면 template_summary. 서비스는 llm.OpenAILocationWriter를 넣는다."""
    def location_route_agent(state: GuardianState) -> dict:
        data = collect(state, fetch=fetch, route_client=route_client, place_client=place_client)
        data.evidence += [Evidence(source="user_memory", key="사용자 기억", value=m)
                          for m in state.get("user_memory") or []]
        summary, how = None, "템플릿"
        if writer is not None and (data.place is not None or data.chosen is not None):
            try:
                summary, how = writer(state.get("question") or "", evidence_lines(data.evidence), data,
                                      state.get("manager_feedback") or ""), "LLM"
            except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                logger.warning("위치·경로 agent 문장 작성 실패 → 템플릿 (%s: %s)", type(e).__name__, e)
        summary = strip_deferrals(summary, RISK_TOPICS) if summary else template_summary(data)
        logger.info("위치·경로 agent [%s] 목적지=%s(%s) 대피소=%s 안전=%s 경로=%s", how, data.destination_query,
                    (data.place or {}).get("source") or data.place_missing, (data.chosen or {}).get("name"),
                    (data.chosen or {}).get("safe"), (data.route or {}).get("available"))
        return {"specialist_results": [SpecialistResult(
            agent=Specialist.LOCATION_ROUTE, summary=summary, evidence=data.evidence, route=route_info(data))]}

    return location_route_agent
