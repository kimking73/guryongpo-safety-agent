"""agent가 쓰는 데이터 조회 tool.

B3(2026-10-01)부터 DB를 직접 읽기 전용으로 조회한다 (db.py, 계정은 db/init/07_ai_readonly.sh).
테이블·뷰는 A 레인이 만든 것을 그대로 읽는다: risk_assessments, v_latest_observations, weather_warnings,
disaster_messages, hazard_zones, shelters, medical_facilities, manholes, action_guides.
request_route만 HTTP(route 서비스, B7). get_user_profile은 아직 목업(앱이 요청에 프로필을 실어 보낸다).

공통 규칙
- 반환은 dict: {"available": True, ..., "source": "<테이블>"}. 조회 실패(DB 꺼짐·시간 초과)는 예외 대신
  {"available": False, "reason": …} — agent가 "지금 확인할 수 없다"고 답하게 (재난 중 답변이 끊기지 않게).
- 답변에 쓸 수치는 반환값 그대로 Evidence에 남긴다 (환각 검증이 대조).
- 좌표는 WGS84(lat, lon), 시간은 ISO 8601(KST, +09:00), 거리는 m 정수.
- fetch: 테스트에서 가짜 조회 함수를 넣을 때만 쓴다. 없으면 실제 DB(db.default_fetch).
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Literal

import httpx

from .db import Fetch, default_fetch
from .state import Mobility, UserProfile

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))

HazardKind = Literal["landslide"]              # 고정 위험지역은 산사태만 (A가 2026-09-28 침수·해안 레이어 삭제)
FacilityKind = Literal["shelter", "medical", "manhole"]
# 파고·조위는 아직 수집하지 않는다 (이월 항목: 조위 데이터 A에게 제안)
ObservationKind = Literal["water_level", "rain", "wind", "uv", "air"]

# 관측 종류 → (관측소 kind, 지표). DB 주석(01_schema.sql observations) 기준
OBSERVATION_METRICS: dict[str, tuple[list[str], list[str]]] = {
    # 지표면 침수심·하천 수위·맨홀 수위 (포항 DT, mm). 맨홀은 수치보다 source_level(등급)로 판단한다
    "water_level": (["road_flood", "river_level", "manhole"], ["flood_depth", "river_level", "manhole_level"]),
    # 포항 DT 강우량계 + 기상청 AWS(15분·1시간·12시간·일 누적) + 초단기실황
    "rain": (["rain_gauge", "weather"], ["rain_15m", "rain_1h", "rain_12h", "rain_day"]),
    # 기상청 AWS(평균·순간최대) + 초단기실황
    "wind": (["weather"], ["wind_speed", "wind_gust", "wind_dir"]),
    "uv": (["uv"], ["uv_index"]),
    "air": (["air"], ["pm10", "pm25"]),
}
# 포항 DT 등급 (observations.source_level)
DT_LEVEL_KO = {1: "정상", 2: "보통", 3: "주의", 4: "경보", 5: "위험"}
# 이보다 오래된 관측값은 stale=True. 초단기실황은 매시 정시 값이 40분쯤 뒤 들어와 최대 100분까지 늦을 수 있다
STALE_MIN = 120
# 판정 엔진이 이보다 오래 안 돌았으면 "정상"을 믿을 수 없다 (A의 /risk data_stale과 같은 기준)
RISK_STALE_MIN = 30

# 경로 안내 서버 (request_route). 컨테이너 안에서는 compose가 ROUTE_URL=http://route:8002를 넣는다.
DEFAULT_ROUTE_URL = "http://localhost:8002"
# 회피 경로는 GraphHopper를 두 번 부르므로 여유 있게. 넘으면 available=False로 답한다.
ROUTE_TIMEOUT_S = 8.0
# 이 나이부터 노약자 경로(경사·계단 회피)를 쓴다
ELDERLY_AGE = 65


# --- 공통 -----------------------------------------------------------------

def _iso(t: Any) -> str | None:
    if t is None:
        return None
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    return t.astimezone(KST).isoformat(timespec="seconds")


def _age_min(t: Any, now: datetime) -> float | None:
    if t is None:
        return None
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    return (now - t).total_seconds() / 60


def _query(fetch: Fetch | None, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
    return (fetch or default_fetch)(sql, params)


def _unavailable(source: str, e: Exception) -> dict[str, Any]:
    logger.warning("DB 조회 실패 [%s] %s: %s", source, type(e).__name__, e)
    return {"available": False, "reason": f"{source} 데이터를 지금 확인할 수 없습니다 ({type(e).__name__})",
            "source": source}


def _point(lat: float, lon: float) -> dict[str, float]:
    return {"lat": lat, "lon": lon}


POINT = "ST_SetSRID(ST_MakePoint(%(lon)s, %(lat)s), 4326)"


# --- 위험 판정 --------------------------------------------------------------

RISK_SQL = f"""
SELECT DISTINCT ON (ra.hazard) ra.id, ra.hazard::text AS hazard, ra.level::text AS level, ra.label, ra.rule_id,
       ra.basis, ra.computed_at, ST_Distance(ra.area::geography, {POINT}::geography) AS distance_m
FROM risk_assessments ra
WHERE ra.valid_to IS NULL AND ST_DWithin(ra.area::geography, {POINT}::geography, %(radius_m)s)
ORDER BY ra.hazard, ra.level DESC, distance_m, ra.id
"""
RISK_LAST_RUN_SQL = "SELECT max(finished_at) AS t FROM ingest_runs WHERE source_code = 'risk' AND status = 'success'"
LEVEL_ORDER = ["normal", "watch", "advisory", "warning", "critical"]


def get_risk_at(lat: float, lon: float, radius_m: int = 500, fetch: Fetch | None = None) -> dict[str, Any]:
    """좌표 반경 안의 현재 위험 판정 — 재난별 가장 높은 단계 1건 (테이블: risk_assessments, A3·A4 판정 엔진).

    items[].reason은 판정 엔진이 쓴 근거 문장(예: "구룡포수협 지표면 수위계 침수심 160mm (기준 150mm)").
    data_stale=True면 판정이 30분 넘게 안 돌았다 → "정상"이라고 단정하지 말 것.
    사용: 관리자(재난 단계 판정), 모든 전문 agent
    """
    source = "risk_assessments"
    try:
        rows = _query(fetch, RISK_SQL, {**_point(lat, lon), "radius_m": radius_m})
        last = (_query(fetch, RISK_LAST_RUN_SQL, {}) or [{}])[0].get("t")
    except Exception as e:  # noqa: BLE001 — 어떤 DB 오류든 답변은 이어 가야 한다
        return _unavailable(source, e)
    items = []
    for r in rows:
        b = r["basis"] if isinstance(r["basis"], dict) else json.loads(r["basis"] or "{}")
        item = {"hazard": r["hazard"], "level": r["level"], "label": r["label"], "reason": b.get("reason"),
                "metric": b.get("metric"), "value": b.get("value"), "unit": b.get("unit"),
                "distance_m": round(float(r["distance_m"])), "observed_at": _iso(b.get("observed_at")),
                "rule_id": r["rule_id"]}
        if b.get("simulated"):
            item["simulated"] = True        # 시연용 모의값 (internal/simulate)
        items.append(item)
    items.sort(key=lambda x: (-LEVEL_ORDER.index(x["level"]), x["distance_m"], x["hazard"]))
    now = datetime.now(KST)
    age = _age_min(last, now)
    return {"available": True, "max_level": items[0]["level"] if items else "normal", "items": items,
            "assessed_at": _iso(last), "data_stale": age is None or age > RISK_STALE_MIN, "source": source}


# --- 관측값 -----------------------------------------------------------------

OBS_SQL = f"""
SELECT o.station_id, o.station_name, o.kind AS station_kind, o.metric, o.value, o.unit, o.source_level, o.observed_at,
       ST_Distance(o.geom::geography, {POINT}::geography) AS distance_m
FROM v_latest_observations o
WHERE o.kind = ANY(%(kinds)s) AND o.metric = ANY(%(metrics)s)
ORDER BY distance_m, o.station_id, o.metric
"""


def get_observations(kind: ObservationKind, lat: float, lon: float, fetch: Fetch | None = None) -> dict[str, Any]:
    """관측소별 최신 관측값, 가까운 관측소부터 (뷰: v_latest_observations).

    kind: water_level(침수심·하천·맨홀, mm), rain(강우량), wind(풍속·돌풍·풍향), uv, air(미세먼지 — 아직 수집 권한 없음).
    items[].level_label은 포항 디지털 트윈 등급(정상~위험), stale=True면 2시간 넘은 값.
    사용: 호우/침수, 강풍/태풍, 생활안전 agent
    """
    source = "observations"
    kinds, metrics = OBSERVATION_METRICS[kind]
    try:
        rows = _query(fetch, OBS_SQL, {**_point(lat, lon), "kinds": kinds, "metrics": metrics})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    now = datetime.now(KST)
    items = []
    for r in rows:
        age = _age_min(r["observed_at"], now)
        items.append({
            "station": r["station_name"], "station_kind": r["station_kind"], "metric": r["metric"],
            "value": r["value"], "unit": r["unit"],
            "level_label": DT_LEVEL_KO.get(r["source_level"]) if r["source_level"] is not None else None,
            "observed_at": _iso(r["observed_at"]), "distance_m": round(float(r["distance_m"])),
            "stale": age is None or age > STALE_MIN,
        })
    return {"available": True, "kind": kind, "items": items, "source": source}


# --- 특보·재난문자 ----------------------------------------------------------

WARNINGS_SQL = """
SELECT hazard::text AS hazard, level::text AS level, region_name, issued_at, effective_at, released_at, headline
FROM weather_warnings
WHERE released_at IS NULL OR released_at > now() - make_interval(hours => %(lifted_hours)s)
ORDER BY (released_at IS NOT NULL), level DESC, issued_at DESC
"""


def get_weather_warnings(lifted_hours: int = 24, fetch: Fetch | None = None) -> dict[str, Any]:
    """발효 중인 기상특보 + 최근 lifted_hours 안에 해제된 특보 (테이블: weather_warnings, 기상청).

    status: "planned"(예비특보, level=watch) | "active" | "lifted"(해제). 재난 '후' 판단에 해제 시각을 쓴다.
    사용: 관리자(재난 단계 판정), 호우/침수, 강풍/태풍 agent
    """
    source = "weather_warnings"
    try:
        rows = _query(fetch, WARNINGS_SQL, {"lifted_hours": lifted_hours})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    items = [{
        "hazard": r["hazard"], "level": r["level"], "region": r["region_name"], "headline": r["headline"],
        "status": "lifted" if r["released_at"] else ("planned" if r["level"] == "watch" else "active"),
        "issued_at": _iso(r["issued_at"]), "effective_at": _iso(r["effective_at"]), "lifted_at": _iso(r["released_at"]),
    } for r in rows]
    return {"available": True, "items": items, "source": source}


MESSAGES_SQL = """
SELECT sent_at, sender, region_name, category, hazard::text AS hazard, alert_class, message
FROM disaster_messages
WHERE sent_at > now() - make_interval(hours => %(hours)s)
ORDER BY sent_at DESC
LIMIT 20
"""


def get_disaster_messages(hours: int = 6, fetch: Fetch | None = None) -> dict[str, Any]:
    """최근 재난문자 (테이블: disaster_messages, 재난안전24 — 키 받기 전까지 비어 있다)."""
    source = "disaster_messages"
    try:
        rows = _query(fetch, MESSAGES_SQL, {"hours": hours})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    items = [{"sent_at": _iso(r["sent_at"]), "sender": r["sender"], "region": r["region_name"],
              "category": r["category"], "hazard": r["hazard"], "alert_class": r["alert_class"],
              "text": r["message"]} for r in rows]
    return {"available": True, "items": items, "source": source}


# --- 위험지역·시설 ----------------------------------------------------------

ZONES_SQL = f"""
SELECT id, hazard::text AS hazard, name, grade, ST_Intersects(geom, {POINT}) AS contains_point,
       ST_Distance(geom::geography, {POINT}::geography) AS distance_m
FROM hazard_zones
WHERE hazard = %(hazard)s::hazard_type AND ST_DWithin(geom::geography, {POINT}::geography, %(radius_m)s)
ORDER BY distance_m, id
LIMIT %(limit)s
"""


def get_hazard_zones(lat: float, lon: float, radius_m: int = 1000, kind: HazardKind = "landslide",
                     limit: int = 5, fetch: Fetch | None = None) -> dict[str, Any]:
    """좌표 반경에 걸친 고정 위험지역 (테이블: hazard_zones, 산사태 취약지역 488곳).

    contains_point=True면 그 지점이 구역 안. 사용: 산사태 agent
    """
    source = "hazard_zones"
    try:
        rows = _query(fetch, ZONES_SQL, {**_point(lat, lon), "hazard": kind, "radius_m": radius_m, "limit": limit})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    items = [{"zone_id": r["id"], "hazard": r["hazard"], "name": r["name"], "grade": r["grade"],
              "contains_point": bool(r["contains_point"]), "distance_m": round(float(r["distance_m"]))} for r in rows]
    return {"available": True, "items": items, "source": source}


SHELTERS_SQL = f"""
SELECT id, name, shelter_types, address, capacity, phone, is_indoor, is_accessible,
       ST_Y(geom) AS lat, ST_X(geom) AS lon, ST_Distance(geom::geography, {POINT}::geography) AS distance_m
FROM shelters
WHERE is_open AND (%(shelter_type)s::text IS NULL OR %(shelter_type)s::text = ANY(shelter_types))
ORDER BY distance_m, id
LIMIT %(limit)s
"""
MEDICAL_SQL = f"""
SELECT id, name, kind, address, phone, meta->>'er_phone' AS er_phone, meta->>'emergency_class' AS emergency_class,
       ST_Y(geom) AS lat, ST_X(geom) AS lon, ST_Distance(geom::geography, {POINT}::geography) AS distance_m
FROM medical_facilities
ORDER BY distance_m, id
LIMIT %(limit)s
"""
MANHOLES_SQL = f"""
SELECT id, kind, ST_Y(geom) AS lat, ST_X(geom) AS lon, ST_Distance(geom::geography, {POINT}::geography) AS distance_m
FROM manholes
ORDER BY distance_m, id
LIMIT %(limit)s
"""
_FACILITY_SQL = {"shelter": SHELTERS_SQL, "medical": MEDICAL_SQL, "manhole": MANHOLES_SQL}
_FACILITY_SOURCE = {"shelter": "shelters", "medical": "medical_facilities", "manhole": "manholes"}


def get_facilities(kind: FacilityKind, lat: float, lon: float, limit: int = 5, shelter_type: str | None = None,
                   fetch: Fetch | None = None) -> dict[str, Any]:
    """가까운 시설 (테이블: shelters·medical_facilities·manholes, 생활안전지도·국립중앙의료원·포항 DT).

    shelter_type: 대피소 종류로 거르기 — flood, earthquake, tsunami, civil_defense, heat, cold (None이면 전부).
      2026-10-01 데이터: 구룡포 대피소 19곳은 tsunami 17·civil_defense 2뿐, flood 지정 대피소는 없다 → 침수 때는 None으로 부른다.
    사용: 호우/침수, 위치·경로, 행동 권고 agent
    """
    source = _FACILITY_SOURCE[kind]
    try:
        rows = _query(fetch, _FACILITY_SQL[kind],
                      {**_point(lat, lon), "limit": limit, "shelter_type": shelter_type})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    items = []
    for r in rows:
        item = {k: v for k, v in r.items() if k not in ("distance_m", "lat", "lon")}
        item.update(facility_id=item.pop("id"), lat=round(float(r["lat"]), 6), lon=round(float(r["lon"]), 6),
                    distance_m=round(float(r["distance_m"])))
        items.append(item)
    return {"available": True, "kind": kind, "items": items, "source": source}


# --- 생활안전 ---------------------------------------------------------------

def _grade(value: float | None, bounds: list[tuple[float, str]], below: bool = False) -> str | None:
    """bounds: (상한, 등급) 오름차순, 마지막은 상한 없음. below=False면 '이하', True면 '미만'으로 비교."""
    if value is None:
        return None
    for upper, label in bounds:
        if value < upper if below else value <= upper:
            return label
    return bounds[-1][1]


# 기상청 자외선 5단계 (0–2 낮음 · 3–5 보통 · 6–7 높음 · 8–10 매우높음 · 11+ 위험, 소수점 값 → '미만'으로 비교)
UV_GRADES = [(3, "낮음"), (6, "보통"), (8, "높음"), (11, "매우높음"), (float("inf"), "위험")]
# 환경부 미세먼지·초미세먼지 4단계 (㎍/㎥, '이하')
PM10_GRADES = [(30, "좋음"), (80, "보통"), (150, "나쁨"), (float("inf"), "매우나쁨")]
PM25_GRADES = [(15, "좋음"), (35, "보통"), (75, "나쁨"), (float("inf"), "매우나쁨")]


def get_life_safety(lat: float, lon: float, fetch: Fetch | None = None) -> dict[str, Any]:
    """자외선·미세먼지·초미세먼지 최신값과 등급 (가장 가까운 관측소). 미세먼지는 수집 권한이 나올 때까지 None."""
    uv = get_observations("uv", lat, lon, fetch=fetch)
    air = get_observations("air", lat, lon, fetch=fetch)
    if not uv["available"] and not air["available"]:
        return {**uv, "source": "observations"}

    def nearest(obs: dict[str, Any], metric: str) -> dict[str, Any] | None:
        return next((i for i in obs.get("items", []) if i["metric"] == metric), None)

    out: dict[str, Any] = {"available": True, "source": "observations"}
    for key, obs, metric, grades in (("uv", uv, "uv_index", UV_GRADES), ("pm10", air, "pm10", PM10_GRADES),
                                     ("pm25", air, "pm25", PM25_GRADES)):
        item = nearest(obs, metric)
        out[key] = None if item is None else {**item, "grade": _grade(item["value"], grades, below=key == "uv")}
    return out


def get_user_profile(user_id: str) -> dict[str, Any]:
    """사용자 정보 (테이블: users). UserProfile 모델과 같은 키."""
    return {
        "user_id": user_id, "user_type": "resident",
        "home": {"lat": 35.9905, "lon": 129.5560, "label": "집"},
        "age": 67, "mobility": "walk", "occupation": "어업(선박 보유)",
    }


def request_route(
    origin: tuple[float, float],
    destination: tuple[float, float],
    profile: Literal["adult", "elderly"] = "adult",
    avoid_manholes: bool = True,
    client: httpx.Client | None = None,
) -> dict[str, Any]:
    """위험 회피 경로. route 서비스(POST /api/route, B6·B7)를 실제로 호출한다 — 목업이 아닌 첫 tool.

    회피: 침수·산사태 위험지역, (avoid_manholes면) 맨홀. profile: adult 최단 시간(경사 무시), elderly 급경사 회피·같은 경사면 계단 선호.
    좌표는 (lat, lon). 반환: route 서비스 응답 키 + available=True.
    경로 서버가 없거나 경로를 못 찾으면 예외 대신 {"available": False, "reason": …}를 돌려준다
    (agent가 "경로 안내를 지금 할 수 없다"고 답하고 대피소 위치만 알려 주도록).
    client: 테스트에서 가짜 route 서버를 넣을 때만 쓴다. 없으면 ROUTE_URL 환경 변수의 서버를 부른다.
    """
    body = {
        "origin": {"lat": origin[0], "lon": origin[1]},
        "destination": {"lat": destination[0], "lon": destination[1]},
        "profile": profile, "avoid_manholes": avoid_manholes,
    }
    own = client is None
    http = client or httpx.Client(base_url=os.environ.get("ROUTE_URL") or DEFAULT_ROUTE_URL,
                                  timeout=ROUTE_TIMEOUT_S)
    try:
        res = http.post("/api/route", json=body)
    except httpx.HTTPError as e:
        return {"available": False, "reason": f"경로 안내 서버에 연결할 수 없습니다 ({type(e).__name__})",
                "source": "route"}
    finally:
        if own:
            http.close()
    if res.status_code != 200:
        try:
            detail = res.json().get("detail")
        except ValueError:
            detail = None
        return {"available": False, "reason": detail or f"경로 안내 오류 (HTTP {res.status_code})", "source": "route"}
    return {**res.json(), "available": True}


def route_profile(user: UserProfile) -> Literal["adult", "elderly"]:
    """사용자 정보 → request_route의 profile. 위치·경로 agent(B4)가 경로를 요청할 때 쓴다.

    65세 이상, 보행이 불편함, 휠체어 이용, 보호가 필요한 동반자 중 하나라도 → elderly (급경사를 피하는 느린 경로).
    그 밖에는 adult. 정보가 없으면 adult로 두고, agent가 필요하면 묻는다.
    휠체어 전용 경로는 두지 않는다 (사용자 결정 2026-09-26) — 휠체어 이용자도 노약자 경로를 쓴다.
    """
    if ((user.age is not None and user.age >= ELDERLY_AGE) or user.walking_impaired
            or user.mobility == Mobility.WHEELCHAIR or user.has_dependents):
        return "elderly"
    return "adult"



# --- 행동요령 ---------------------------------------------------------------

GUIDES_SQL = """
SELECT id, hazard::text AS disaster, phase::text AS phase, min_level::text AS min_level, targets, priority,
       title, content, voice_text, source_name, source_url
FROM action_guides
WHERE hazard = %(hazard)s::hazard_type AND phase = %(phase)s::phase_type
  AND min_level <= %(level)s::risk_level AND targets && %(targets)s::text[]
ORDER BY priority, id
"""


def get_action_guides(disaster: str, phase: Literal["before", "during", "after"], level: str = "advisory",
                      targets: list[str] | None = None, fetch: Fetch | None = None) -> dict[str, Any]:
    """행동요령 원문 (테이블: action_guides, A7 적재 — 포항시 재난안전 홈페이지 등). 우선순위 순.

    level: 현재 위험 단계. 그 단계 이하의 min_level 문장만 나온다 (주의보 때 경보용 대피 문장이 섞이지 않게).
    targets: 사용자 유형 — resident, tourist, fisher, vessel_owner, coastal, farmer, driver. "all"은 항상 포함.
    items는 state.ActionGuide와 같은 키. 행동 권고 agent는 여기 있는 문장만 인용한다 (지어내지 않는다).
    """
    source = "action_guides"
    try:
        rows = _query(fetch, GUIDES_SQL, {"hazard": disaster, "phase": phase, "level": level,
                                          "targets": ["all", *(targets or [])]})
    except Exception as e:  # noqa: BLE001
        return _unavailable(source, e)
    return {"available": True, "items": [dict(r) for r in rows], "source": source}


# agent별로 쓸 수 있는 tool.
AGENT_TOOLS: dict[str, list] = {
    "manager": [get_risk_at, get_weather_warnings, get_user_profile],
    "landslide_agent": [get_risk_at, get_hazard_zones, get_observations, get_weather_warnings],
    "rain_flood_agent": [get_risk_at, get_observations, get_weather_warnings,
                         get_disaster_messages, get_facilities],
    "wind_typhoon_agent": [get_risk_at, get_observations, get_weather_warnings, get_disaster_messages],
    "life_safety_agent": [get_life_safety],
    "location_route_agent": [get_risk_at, get_facilities, request_route],
    "action_advisor": [get_action_guides, get_facilities],
}
