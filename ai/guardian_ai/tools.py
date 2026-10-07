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

from . import demo
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
    f = fetch or default_fetch
    if demo.is_active():   # 앱 시연 모드: 실시간 표를 서버 시연 데이터로 가린 SQL (demo.py)
        f = demo.demo_fetch(f)
    return f(sql, params)


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

# 관측소×지표마다 1건: 시연용 모의값(quality='simulated')이 6시간 안에 있으면 그것, 아니면 최신 실측.
# A의 판정 엔진과 같은 우선순위(risk/engine.py SIM_MAX_AGE_MIN) — 판정은 "경보"인데 근거 수치는 실측 0mm인 모순을 막는다.
# (v_latest_observations는 최신값만 보므로 쓰지 않는다.) 최근 2일로 범위를 묶어 오래된 행을 훑지 않는다.
SIM_PRIORITY_HOURS = 6
OBS_SQL = f"""
SELECT * FROM (
  SELECT DISTINCT ON (o.station_id, o.metric)
         s.id AS station_id, s.name AS station_name, s.kind AS station_kind, o.metric, o.value, o.unit,
         o.source_level, o.observed_at, (o.quality IS NOT DISTINCT FROM 'simulated') AS simulated,
         ST_Distance(s.geom::geography, {POINT}::geography) AS distance_m
  FROM observations o JOIN stations s ON s.id = o.station_id
  WHERE s.is_active AND s.kind = ANY(%(kinds)s) AND o.metric = ANY(%(metrics)s)
    AND o.observed_at > now() - interval '2 days'
  ORDER BY o.station_id, o.metric,
           (o.quality IS NOT DISTINCT FROM 'simulated' AND o.observed_at > now() - interval '{SIM_PRIORITY_HOURS} hours') DESC,
           o.observed_at DESC
) latest
ORDER BY distance_m, station_id, metric
"""


def get_observations(kind: ObservationKind, lat: float, lon: float, fetch: Fetch | None = None) -> dict[str, Any]:
    """관측소별 최신 관측값, 가까운 관측소부터 (테이블: observations + stations).

    kind: water_level(침수심·하천·맨홀, mm), rain(강우량), wind(풍속·돌풍·풍향), uv, air(미세먼지 — 아직 수집 권한 없음).
    items[].level_label은 포항 디지털 트윈 등급(정상~위험), stale=True면 2시간 넘은 값,
    simulated=True면 시연 시나리오가 넣은 모의값 (6시간 동안 실측보다 우선 — 판정 엔진과 같은 규칙).
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
        if r.get("simulated"):
            items[-1]["simulated"] = True
    return {"available": True, "kind": kind, "items": items, "source": source}


# --- 예보 (기상청 초단기·단기, A가 수집 — forecasts / v_latest_forecasts) ---------------

# 구룡포 격자 (A의 collector KMA_GRIDS): (105,94) 읍 중심, (106,94) 구룡포항. 경도로 가까운 쪽을 고른다
FORECAST_GRIDS = {(105, 94): 129.5481, (106, 94): 129.5650}
FORECAST_SQL = """
SELECT kind, fcst_time, category, value, value_num
FROM v_latest_forecasts
WHERE kind = ANY(%(kinds)s) AND grid_nx = %(nx)s AND grid_ny = %(ny)s
  AND fcst_time > now() AND fcst_time <= now() + make_interval(hours => %(hours)s)
  AND category = ANY(%(categories)s)
ORDER BY fcst_time, category
"""
PTY_KO = {1: "비", 2: "비/눈", 3: "눈", 4: "소나기", 5: "빗방울", 6: "빗방울눈날림", 7: "눈날림"}


def get_forecast(lat: float, lon: float, hours: int = 48, fetch: Fetch | None = None) -> dict[str, Any]:
    """앞으로 hours시간 예보 요약 (초단기 6시간 + 단기 ~3일, 가까운 시각은 초단기 우선).

    반환: grid, periods(날짜별: max_pop 강수확률 %, rain_types 강수형태, rain_hours 비 예보 시각 수, max_rain 1시간 강수량 문구,
    max_wind m/s, max_wave m), next_rain(가장 이른 비 예보 시각·형태), issued(발표 시각).
    사용: 재난 전 판단(행동 권고), 호우·침수, 강풍·태풍 agent
    """
    grid = min(FORECAST_GRIDS, key=lambda g: abs(FORECAST_GRIDS[g] - lon))
    try:
        rows = _query(fetch, FORECAST_SQL, {"kinds": ["ultra_short", "short"], "nx": grid[0], "ny": grid[1], "hours": hours,
                                            "categories": ["POP", "PTY", "PCP", "RN1", "WSD", "WAV"]})
    except Exception as e:  # noqa: BLE001
        return _unavailable("forecasts", e)
    if not rows:
        return {"available": False, "reason": "예보 없음 (수집 확인)", "source": "forecasts"}
    # 같은 시각·항목은 초단기가 단기보다 우선
    best: dict[tuple, dict] = {}
    for r in rows:
        key = (r["fcst_time"], "RN1" if r["category"] == "PCP" else r["category"])
        if key not in best or r["kind"] == "ultra_short":
            best[key] = r
    days: dict[str, dict[str, Any]] = {}
    next_rain = None
    for (t, cat), r in sorted(best.items(), key=lambda kv: kv[0][0]):
        local = t.astimezone(KST) if hasattr(t, "astimezone") else datetime.fromisoformat(str(t)).astimezone(KST)
        d = days.setdefault(local.strftime("%m-%d"), {"date": local.strftime("%m-%d"), "max_pop": None, "rain_types": [],
                                                      "rain_hours": 0, "max_rain": None, "max_wind": None, "max_wave": None})
        v = r["value_num"]
        if cat == "POP" and v is not None:
            d["max_pop"] = max(d["max_pop"] or 0, int(v))
        elif cat == "PTY" and v:
            kind = PTY_KO.get(int(v))
            if kind and kind not in d["rain_types"]:
                d["rain_types"].append(kind)
            d["rain_hours"] += 1
            if next_rain is None:
                next_rain = {"at": _iso(t), "type": kind}
        elif cat == "RN1" and r["value"] not in ("강수없음", "0"):
            if d["max_rain"] is None or (v or 0) > d.get("_rain_num", -1):
                d["max_rain"], d["_rain_num"] = r["value"], v or 0
        elif cat == "WSD" and v is not None:
            d["max_wind"] = max(d["max_wind"] or 0, round(float(v), 1))
        elif cat == "WAV" and v is not None:
            d["max_wave"] = max(d["max_wave"] or 0, round(float(v), 1))
    periods = [{k: v for k, v in d.items() if not k.startswith("_")} for d in days.values()]
    return {"available": True, "grid": list(grid), "periods": periods, "next_rain": next_rain, "source": "forecasts"}


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


# 대피 후보 판단 — 앱(app/lib/repositories/remote_repository.dart shelterSafety)과 같은 규칙:
#   ① 지금 발효 중인 침수·산사태 영역(주의 이상) 안의 대피소는 뺀다 (호우 영역은 읍 전체라 판단에 쓰지 않는다)
#   ② 침수 영역이 하나라도 발효 중이면 지하 대피소(이름에 '지하')도 뺀다 — 물이 먼저 차는 곳
AVOID_HAZARDS = ("flood", "landslide")
SAFE_SHELTERS_SQL = f"""
SELECT s.id, s.name, s.shelter_types, s.address, s.is_indoor,
       ST_Y(s.geom) AS lat, ST_X(s.geom) AS lon, ST_Distance(s.geom::geography, {{POINT}}::geography) AS distance_m,
       (SELECT string_agg(DISTINCT ra.label, ', ') FROM risk_assessments ra
         WHERE ra.valid_to IS NULL AND ra.level >= 'advisory' AND ra.hazard::text = ANY(%(hazards)s)
           AND ST_Intersects(ra.area, s.geom)) AS in_hazard,
       s.name LIKE '%%지하%%' AS underground,
       EXISTS (SELECT 1 FROM risk_assessments ra WHERE ra.valid_to IS NULL AND ra.level >= 'advisory'
               AND ra.hazard = 'flood') AS flood_active
FROM shelters s
WHERE s.is_open
ORDER BY distance_m, s.id
LIMIT %(limit)s
""".replace("{POINT}", POINT)


def get_safe_shelters(lat: float, lon: float, limit: int = 8, fetch: Fetch | None = None) -> dict[str, Any]:
    """가까운 대피소 + 지금 갈 만한지 (테이블: shelters, risk_assessments).

    items[]: name, lat, lon, distance_m(직선), is_indoor, underground, safe, excluded_reason(뺀 이유, safe면 None).
    safe=True인 곳이 없으면 위치·경로 agent가 가장 가까운 곳을 경고와 함께 안내한다.
    사용: 위치·경로 agent
    """
    try:
        rows = _query(fetch, SAFE_SHELTERS_SQL, {**_point(lat, lon), "limit": limit, "hazards": list(AVOID_HAZARDS)})
    except Exception as e:  # noqa: BLE001
        return _unavailable("shelters", e)
    items = []
    for r in rows:
        reason = None
        if r["in_hazard"]:
            reason = f"위험 영역 안({r['in_hazard']})"
        elif r["underground"] and r["flood_active"]:
            reason = "침수 중 지하 시설"
        items.append({"facility_id": r["id"], "name": r["name"], "shelter_types": list(r["shelter_types"] or []),
                      "is_indoor": bool(r["is_indoor"]), "underground": bool(r["underground"]),
                      "lat": round(float(r["lat"]), 6), "lon": round(float(r["lon"]), 6),
                      "distance_m": round(float(r["distance_m"])), "safe": reason is None, "excluded_reason": reason})
    return {"available": True, "items": items, "source": "shelters"}


HAZARDS_AT_SQL = f"""
SELECT string_agg(DISTINCT ra.label, ', ') AS labels
FROM risk_assessments ra
WHERE ra.valid_to IS NULL AND ra.level >= 'advisory' AND ra.hazard::text = ANY(%(hazards)s)
  AND ST_Intersects(ra.area, {POINT})
"""


def hazards_at(lat: float, lon: float, fetch: Fetch | None = None) -> dict[str, Any]:
    """이 지점이 지금 발효 중인 침수·산사태 영역(주의 이상) 안인지 (대피소 규칙과 같은 기준). labels: "침수 경보, …" 또는 None"""
    try:
        rows = _query(fetch, HAZARDS_AT_SQL, {**_point(lat, lon), "hazards": list(AVOID_HAZARDS)})
    except Exception as e:  # noqa: BLE001
        return _unavailable("risk_assessments", e)
    return {"available": True, "labels": (rows or [{}])[0].get("labels"), "source": "risk_assessments"}


# --- 목적지 찾기 (위치·경로 agent) ---------------------------------------------

# 카카오 로컬 키워드 검색. 기준점은 구룡포읍 중심으로 고정한다 — 사용자 위치를 외부 서비스로 보내지 않는다.
KAKAO_URL = "https://dapi.kakao.com"
KAKAO_TIMEOUT_S = 3.0
KAKAO_RADIUS_M = 20000
GURYONGPO_CENTER = (35.9858, 129.5481)
# 경로 서버(GraphHopper) 도로망 범위 (graphhopper/fetch_osm.sh BBOX). 이 밖은 걸어서 안내할 수 없다
ROUTE_BOUNDS = (35.92, 129.48, 36.04, 129.60)   # 남, 서, 북, 동
HOME_WORDS = ("집", "우리집", "우리 집", "자택")
WORK_WORDS = ("직장", "회사", "일터", "작업장")

PLACE_SQL = """
(SELECT name, ST_Y(geom) AS lat, ST_X(geom) AS lon, 'shelter' AS kind FROM shelters
  WHERE is_open AND name ILIKE %(q)s ORDER BY length(name) LIMIT 1)
UNION ALL
(SELECT name, ST_Y(geom) AS lat, ST_X(geom) AS lon, 'medical' AS kind FROM medical_facilities
  WHERE name ILIKE %(q)s ORDER BY length(name) LIMIT 1)
"""


def _in_route_bounds(lat: float, lon: float) -> bool:
    s, w, n, e = ROUTE_BOUNDS
    return s <= lat <= n and w <= lon <= e


def _user_place(query: str, user: UserProfile | None) -> dict[str, Any] | None:
    if user is None:
        return None
    q = query.replace(" ", "")
    if user.home and (q in [w.replace(" ", "") for w in HOME_WORDS] or (user.home.label and q == user.home.label.replace(" ", ""))):
        return {"name": user.home.label or "집", "lat": user.home.lat, "lon": user.home.lon, "kind": "home"}
    for p in user.frequent_places:
        label = (p.label or "").replace(" ", "")
        if label and (label in q or q in label or (q in WORK_WORDS and label == "직장")):
            return {"name": p.label, "lat": p.lat, "lon": p.lon, "kind": "work" if label == "직장" else "place"}
    return None


def find_place(query: str, user: UserProfile | None = None, fetch: Fetch | None = None,
               client: httpx.Client | None = None) -> dict[str, Any]:
    """목적지 이름 → 좌표. 순서: ① 사용자 등록 장소(집·직장·등록 이름) ② DB 시설 이름(대피소·의료시설) ③ 카카오 장소 검색.

    반환: available, name, lat, lon, kind(home·work·place·shelter·medical), source(user·db·kakao), address(카카오만).
    카카오는 KAKAO_REST_KEY가 없으면 건너뛴다. 결과가 경로 서버 범위 밖이면 out_of_area=True로 돌려준다.
    client: 테스트에서 가짜 카카오 서버를 넣을 때만.
    사용: 위치·경로 agent
    """
    query = (query or "").strip()
    if not query:
        return {"available": False, "reason": "목적지 없음"}
    if (p := _user_place(query, user)) is not None:
        return {"available": True, **p, "source": "user"}
    if query.replace(" ", "") in [w.replace(" ", "") for w in (*HOME_WORDS, *WORK_WORDS)]:
        return {"available": False, "reason": f"등록된 '{query}' 위치가 없음 (앱 프로필에서 장소 등록)"}
    try:
        rows = _query(fetch, PLACE_SQL, {"q": f"%{query}%"})
    except Exception as e:  # noqa: BLE001 — DB가 없어도 카카오로 이어 간다
        logger.warning("시설 이름 검색 실패 (%s)", type(e).__name__)
        rows = []
    if rows:
        r = rows[0]
        return {"available": True, "name": r["name"], "lat": round(float(r["lat"]), 6), "lon": round(float(r["lon"]), 6),
                "kind": r["kind"], "source": "db"}

    key = os.environ.get("KAKAO_REST_KEY")
    if not key and client is None:
        return {"available": False, "reason": f"'{query}'을(를) 등록 장소·시설에서 찾지 못함 (장소 검색 키 없음)"}
    own = client is None
    http = client or httpx.Client(base_url=os.environ.get("KAKAO_URL") or KAKAO_URL, timeout=KAKAO_TIMEOUT_S)
    try:
        res = http.get("/v2/local/search/keyword.json", headers={"Authorization": f"KakaoAK {key}"} if key else {},
                       params={"query": query, "x": GURYONGPO_CENTER[1], "y": GURYONGPO_CENTER[0],
                               "radius": KAKAO_RADIUS_M, "size": 5, "sort": "accuracy"})
        res.raise_for_status()
        docs = res.json().get("documents") or []
    except (httpx.HTTPError, ValueError) as e:
        logger.warning("카카오 장소 검색 실패 (%s)", type(e).__name__)
        return {"available": False, "reason": f"장소 검색을 지금 할 수 없음 ({type(e).__name__})", "source": "kakao"}
    finally:
        if own:
            http.close()
    if not docs:
        return {"available": False, "reason": f"'{query}'을(를) 구룡포 근처에서 찾지 못함", "source": "kakao"}
    places = [{"name": d["place_name"], "lat": round(float(d["y"]), 6), "lon": round(float(d["x"]), 6),
               "address": d.get("road_address_name") or d.get("address_name")} for d in docs]
    inside = [p for p in places if _in_route_bounds(p["lat"], p["lon"])]
    if not inside:
        return {"available": True, **places[0], "kind": "place", "source": "kakao", "out_of_area": True}
    return {"available": True, **inside[0], "kind": "place", "source": "kakao"}


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


# 사용자 프로필 (서버 기준, 2026-10-08 — 사용자 결정: 프로필을 하나의 기준으로). 앱이 계정 동기화로 올린 값이다
USER_PROFILE_SQL = """
SELECT u.id::text AS user_id, p.user_type::text AS user_type, p.birth_year, p.mobility::text AS mobility,
       p.walking_ability::text AS walking_ability, p.has_dependents, p.occupation, p.vision_impaired, p.hearing_impaired
FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id
WHERE u.firebase_uid = %(uid)s
"""
USER_PLACES_SQL = """
SELECT pl.place_type::text AS place_type, pl.label, ST_Y(pl.geom) AS lat, ST_X(pl.geom) AS lon
FROM user_places pl JOIN users u ON u.id = pl.user_id
WHERE u.firebase_uid = %(uid)s
ORDER BY pl.created_at
"""
_MOBILITY_DB = {"walk": "walk", "car": "car", "wheelchair": "wheelchair", "public_transit": "public_transport"}


def get_user_profile(uid: str, fetch: Fetch | None = None, today: datetime | None = None) -> dict[str, Any]:
    """로그인 uid(Firebase) → 서버에 저장된 사용자 프로필 (테이블: users·user_profiles·user_places, 앱 계정 동기화가 채움).

    반환: {"available": True, "profile": {UserProfile 필드 중 서버에 있는 것}} — 칸이 비어 있으면 빼서, 부르는 쪽이
    앱이 보낸 값으로 보충할 수 있게 한다. 사용자가 없으면 available=False(reason). 사용: ChatService (모든 agent 공통)
    """
    try:
        rows = _query(fetch, USER_PROFILE_SQL, {"uid": uid})
        places = _query(fetch, USER_PLACES_SQL, {"uid": uid}) if rows else []
    except Exception as e:  # noqa: BLE001
        return _unavailable("user_profiles", e)
    if not rows:
        return {"available": False, "reason": "서버에 사용자 없음", "source": "user_profiles"}
    r = rows[0]
    out: dict[str, Any] = {}
    if r.get("user_type"):            # 구룡포 근무자(worker)는 지리를 아는 주민으로 본다
        out["user_type"] = "tourist" if r["user_type"] == "tourist" else "resident"
    if r.get("birth_year"):
        out["age"] = (today or datetime.now(KST)).year - int(r["birth_year"])
    if r.get("mobility") in _MOBILITY_DB:
        out["mobility"] = _MOBILITY_DB[r["mobility"]]
    # 아래 칸은 DB 기본값(normal·false)이 '입력 안 함'과 구별되지 않아, 해당할 때(true)만 기준으로 쓴다 —
    # false 를 기준으로 쓰면 앱이 보낸 true(예: 보호자 여부는 서버로 안 올라감)를 덮어쓴다 (2026-10-08)
    if r.get("walking_ability") in ("limited", "unable"):
        out["walking_impaired"] = True
    for k in ("has_dependents", "vision_impaired", "hearing_impaired"):
        if r.get(k):
            out["visual_impaired" if k == "vision_impaired" else k] = True
    if (r.get("occupation") or "").strip():
        out["occupation"] = r["occupation"].strip()
    home = next((pl for pl in places if pl["place_type"] == "home"), None)
    if home:
        out["home"] = {"lat": float(home["lat"]), "lon": float(home["lon"]), "label": home["label"] or "집"}
    others = [{"lat": float(pl["lat"]), "lon": float(pl["lon"]), "label": pl["label"]} for pl in places if pl is not home]
    if others:
        out["frequent_places"] = others
    return {"available": True, "profile": out, "source": "user_profiles"}


def request_route(
    origin: tuple[float, float],
    destination: tuple[float, float],
    profile: Literal["adult", "elderly"] = "adult",
    client: httpx.Client | None = None,
) -> dict[str, Any]:
    """위험 회피 경로. route 서비스(POST /api/route, B6·B7)를 실제로 호출한다 — 목업이 아닌 첫 tool.

    회피: 판정 엔진이 지금 낸 침수·산사태 영역(주의 이상). 맨홀은 회피하지 않는다 (사용자 결정 2026-10-02). profile: adult 최단 시간(경사 무시), elderly 급경사 회피·같은 경사면 계단 선호.
    좌표는 (lat, lon). 반환: route 서비스 응답 키 + available=True.
    경로 서버가 없거나 경로를 못 찾으면 예외 대신 {"available": False, "reason": …}를 돌려준다
    (agent가 "경로 안내를 지금 할 수 없다"고 답하고 대피소 위치만 알려 주도록).
    client: 테스트에서 가짜 route 서버를 넣을 때만 쓴다. 없으면 ROUTE_URL 환경 변수의 서버를 부른다.
    """
    body = {
        "origin": {"lat": origin[0], "lon": origin[1]},
        "destination": {"lat": destination[0], "lon": destination[1]},
        "profile": profile,
    }
    return _post_route("/api/route", body, client)


def request_sea_route(
    origin: tuple[float, float],
    destination: tuple[float, float] | None = None,
    profile: Literal["adult", "elderly"] = "adult",
    client: httpx.Client | None = None,
) -> dict[str, Any]:
    """B11 해상 경로 (route 서비스 POST /api/route/sea). 바다 위면 가장 가까운 항구까지 바닷길 + 항구 육상 지점부터 도보 경로.

    반환: route 서비스 응답 키(at_sea, port, sea_leg, destination, land_route, land_route_error) + available=True.
    at_sea=False면 land_route가 출발지부터의 일반 경로(/api/route와 같은 내용)다.
    destination을 생략하면 경로 서버가 항구에서 가까운 갈 만한 대피소를 고른다.
    구룡포 일대 밖(422)·서버 장애는 {"available": False, "reason"} — 위치·경로 agent는 일반 경로로 대신한다.
    """
    body: dict[str, Any] = {"origin": {"lat": origin[0], "lon": origin[1]}, "profile": profile}
    if destination is not None:
        body["destination"] = {"lat": destination[0], "lon": destination[1]}
    return _post_route("/api/route/sea", body, client)


def _post_route(path: str, body: dict[str, Any], client: httpx.Client | None) -> dict[str, Any]:
    if demo.is_active():
        body = {**body, "demo": True}   # 경로 서버도 시연 위험 영역을 피한다 (앱 시연 모드와 같다)
    own = client is None
    http = client or httpx.Client(base_url=os.environ.get("ROUTE_URL") or DEFAULT_ROUTE_URL,
                                  timeout=ROUTE_TIMEOUT_S)
    try:
        res = http.post(path, json=body)
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
    "location_route_agent": [get_risk_at, get_safe_shelters, find_place, hazards_at, request_route, request_sea_route],
    "action_advisor": [get_action_guides, get_facilities],
}
