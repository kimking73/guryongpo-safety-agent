"""맞춤 대시보드 (GET /dashboard) — 전부 실데이터 (2026-10-05, 목업 대체)

위젯 형식은 명세 components.schemas.Widget. 자료가 없으면 data = {"available": false, "reason": "..."} — 앱은 "자료 없음 (사유)" 로 표시.
- warnings        weather_warnings 발효 중(해제 안 됨)
- rain · wind     구룡포 AWS(kma aws_816) 최신값 + 6시간 추이
- water_level     포항 디지털 트윈 하천 수위·맨홀·지표면 수위계 (layers.stations_layer 와 같은 값)
- wave            단기예보 파고(WAV, 구룡포항 격자) — 실측 파고는 수집하지 않음
- forecast        단기예보 다음 12시간 (구룡포읍 격자)
- typhoon         typhoon_tracks 에서 최근 하루 안에 분석·예측이 있는 태풍
- disaster_messages  재난문자 24시간 (수집 키가 없으면 available=false)
- life_safety     자외선지수·미세먼지 (가장 가까운 대기 센서)
"""
from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import db, layers
from risk import queries

KST = timezone(timedelta(hours=9))
LEVEL_NUM = {"normal": 0, "watch": 1, "advisory": 2, "warning": 3, "critical": 4}
AWS = ("kma", "aws_816")
GRID_TOWN, GRID_PORT = (105, 94), (106, 94)     # 구룡포읍 중심 · 구룡포항 (단기예보 격자)
PTY = {"0": "없음", "1": "비", "2": "비/눈", "3": "눈", "4": "소나기", "5": "빗방울", "6": "빗방울눈날림", "7": "눈날림"}
DT_KINDS = ("river_level", "manhole", "road_flood")
WIDGET_ORDER = ["warnings", "rain", "water_level", "wind", "typhoon", "wave", "disaster_messages", "forecast", "life_safety"]
# 재난 → 앞으로 올릴 위젯 (emergency 일 때)
HAZARD_WIDGETS = {"flood": ["water_level", "rain"], "heavy_rain": ["rain", "water_level"], "strong_wind": ["wind"],
                  "typhoon": ["typhoon", "wind", "wave"], "high_seas": ["wave", "wind"], "landslide": ["rain"],
                  "uv": ["life_safety"], "fine_dust": ["life_safety"], "ultrafine_dust": ["life_safety"]}


def _iso(t) -> Optional[str]:
    if t is None:
        return None
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    return t.astimezone(KST).isoformat(timespec="seconds")


def _none(reason: str) -> dict:
    return {"available": False, "reason": reason}


def _km(lat1, lng1, lat2, lng2) -> float:
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lng2 - lng1) * p / 2) ** 2)
    return 12742 * math.asin(math.sqrt(a))


# ------------------------------------------------------------------ 위젯별 조회
WARNINGS_SQL = """
SELECT hazard::text AS hazard, level::text AS level, region_name, issued_at, effective_at, headline
FROM weather_warnings WHERE released_at IS NULL ORDER BY level DESC, issued_at DESC
"""
SERIES_SQL = """
SELECT o.metric, o.value, o.unit, o.observed_at
FROM observations o JOIN stations s ON s.id = o.station_id
WHERE s.source_code = %(src)s AND s.external_id = %(ext)s AND o.metric = ANY(%(metrics)s)
  AND o.observed_at > now() - interval '6 hours' AND o.quality IS DISTINCT FROM 'simulated'
ORDER BY o.observed_at
"""
FORECAST_SQL = """
SELECT DISTINCT ON (fcst_time, category) fcst_time, category, value, value_num
FROM forecasts
WHERE kind = 'short' AND grid_nx = %(nx)s AND grid_ny = %(ny)s AND fcst_time > now() AND fcst_time <= now() + %(span)s::interval
  AND category = ANY(%(cats)s)
ORDER BY fcst_time, category, base_time DESC
"""
TYPHOON_SQL = """
WITH cur AS (
  SELECT typhoon_code FROM typhoon_tracks GROUP BY typhoon_code
  HAVING max(observed_at) > now() - interval '1 day' ORDER BY max(observed_at) DESC LIMIT 1)
SELECT t.typhoon_code, t.name_ko, t.observed_at, t.is_forecast, ST_Y(t.geom) AS lat, ST_X(t.geom) AS lng,
       t.max_wind_ms, t.central_pressure_hpa, t.radius_15ms_km, t.radius_25ms_km, t.speed_kmh, t.direction, t.location_text
FROM typhoon_tracks t JOIN cur USING (typhoon_code)
WHERE NOT t.is_forecast OR t.issued_at = (SELECT max(issued_at) FROM typhoon_tracks x JOIN cur USING (typhoon_code) WHERE x.is_forecast)
ORDER BY t.observed_at
"""
MESSAGES_SQL = """
SELECT sent_at, sender, message, alert_class FROM disaster_messages WHERE sent_at > now() - interval '24 hours'
ORDER BY sent_at DESC LIMIT 10
"""
SAFETY24_SQL = """
SELECT 1 AS ok FROM ingest_runs WHERE source_code = 'safety24' AND status = 'success' AND started_at > now() - interval '1 day' LIMIT 1
"""
UV_AIR_SQL = """
SELECT DISTINCT ON (o.metric) s.name, s.external_id, o.metric, o.value, o.unit, o.observed_at,
       ST_Distance(s.geom::geography, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography) AS dist
FROM observations o JOIN stations s ON s.id = o.station_id
WHERE o.metric IN ('uv_index', 'pm10', 'pm25') AND o.observed_at > now() - interval '3 hours'
  AND o.quality IS DISTINCT FROM 'simulated'
ORDER BY o.metric, dist, o.observed_at DESC
"""


def warnings_widget() -> dict:
    rows = db.fetch_all(WARNINGS_SQL)
    return {"items": [{"label": r["headline"] or r["region_name"], "hazard": r["hazard"], "level": r["level"],
                       "region_name": r["region_name"], "issued_at": _iso(r["issued_at"])} for r in rows]}


def _aws_widget(metric: str, unit: str, extra: tuple[str, ...], level: str) -> dict:
    rows = db.fetch_all(SERIES_SQL, {"src": AWS[0], "ext": AWS[1], "metrics": [metric, *extra]})
    main = [r for r in rows if r["metric"] == metric]
    if not main:
        return _none("구룡포 AWS 관측값이 6시간 동안 없습니다")
    last = main[-1]
    out = {"station_name": "구룡포 AWS (기상청)", "value": last["value"], "unit": unit,
           "observed_at": _iso(last["observed_at"]), "level": level,
           "series": [{"t": _iso(r["observed_at"]), "v": r["value"]} for r in main[-36:]]}
    for m in extra:
        vals = [r for r in rows if r["metric"] == m]
        if vals:
            out[m] = vals[-1]["value"]
    return out


def water_level_widget(stations: list[dict]) -> dict:
    dt = [f for f in stations if f["properties"]["kind"] in DT_KINDS and f["properties"]["observed_at"]]
    if not dt:
        return _none("포항 디지털 트윈 수위 자료가 없습니다")
    items = []
    for f in dt:
        p, (lng, lat) = f["properties"], f["geometry"]["coordinates"]
        items.append({"station_id": f["id"], "station_name": p["name"], "kind": p["kind"], "metric": p["metric"],
                      "value": p["value"], "unit": p["unit"] or "mm", "source_level": p["source_level"],
                      "source_level_label": p["source_level_label"], "level": p["level"] or "normal",
                      "location": {"lat": lat, "lng": lng}, "stale": p["stale"]})
    return {"observed_at": max(i for i in (f["properties"]["observed_at"] for f in dt) if i), "stations": items}


def forecast_slots(nx: int, ny: int, hours: int = 12) -> list[dict]:
    rows = db.fetch_all(FORECAST_SQL, {"nx": nx, "ny": ny, "span": f"{hours} hours",
                                       "cats": ["POP", "PTY", "PCP", "TMP", "WSD", "WAV"]})
    slots: dict[str, dict] = {}
    for r in rows:
        s = slots.setdefault(_iso(r["fcst_time"]), {"t": _iso(r["fcst_time"])})
        v, n = r["value"], r["value_num"]
        if r["category"] == "POP":
            s["pop"] = int(n) if n is not None else None
        elif r["category"] == "PTY":
            s["pty"] = PTY.get(str(v), v)
        elif r["category"] == "PCP":
            s["pcp_mm"] = n if n is not None else 0.0
        elif r["category"] == "TMP":
            s["tmp"] = n
        elif r["category"] == "WSD":
            s["wsd"] = n
        elif r["category"] == "WAV":
            s["wav_m"] = n
    return list(slots.values())


def forecast_widget() -> dict:
    slots = [{k: v for k, v in s.items() if k != "wav_m"} for s in forecast_slots(*GRID_TOWN)]
    return {"slots": slots, "source": "기상청 단기예보 (구룡포읍 격자)"} if slots else _none("기상청 단기예보 자료가 없습니다")


def wave_widget(level: str) -> dict:
    waves = [s for s in forecast_slots(*GRID_PORT, hours=24) if s.get("wav_m") is not None]
    if not waves:
        return _none("파고 실측은 수집하지 않고, 단기예보 파고도 없습니다")
    return {"station_name": "구룡포항 앞바다 (기상청 단기예보 파고)", "value": waves[0]["wav_m"], "unit": "m",
            "observed_at": waves[0]["t"], "level": level, "is_forecast": True,
            "series": [{"t": s["t"], "v": s["wav_m"]} for s in waves]}


def typhoon_widget(lat: float, lng: float) -> dict:
    rows = db.fetch_all(TYPHOON_SQL)
    if not rows:
        return _none("현재 진행 중인 태풍이 없습니다")
    track = [{"t": _iso(r["observed_at"]), "lat": r["lat"], "lng": r["lng"], "is_forecast": bool(r["is_forecast"]),
              "max_wind_ms": r["max_wind_ms"], "radius_15ms_km": r["radius_15ms_km"]} for r in rows]
    closest = min(rows, key=lambda r: _km(lat, lng, r["lat"], r["lng"]))
    now_rows = [r for r in rows if not r["is_forecast"]]
    cur = now_rows[-1] if now_rows else rows[0]
    return {"code": rows[0]["typhoon_code"], "name_ko": rows[0]["name_ko"],
            "distance_km": round(_km(lat, lng, cur["lat"], cur["lng"])),
            "closest_km": round(_km(lat, lng, closest["lat"], closest["lng"])),
            "eta_closest": _iso(closest["observed_at"]), "current": {
                "t": _iso(cur["observed_at"]), "lat": cur["lat"], "lng": cur["lng"], "max_wind_ms": cur["max_wind_ms"],
                "central_pressure_hpa": cur["central_pressure_hpa"], "location_text": cur["location_text"],
                "speed_kmh": cur.get("speed_kmh"), "direction": cur.get("direction"),
                "radius_15ms_km": cur.get("radius_15ms_km"), "radius_25ms_km": cur.get("radius_25ms_km")},
            "track": track, "source": "기상청 태풍 정보"}


def disaster_messages_widget() -> dict:
    if not db.fetch_one(SAFETY24_SQL):
        return _none("재난문자 수집이 아직 연결되지 않았습니다 (재난안전데이터 API 키 필요)")
    return {"items": [{"sent_at": _iso(r["sent_at"]), "sender": r["sender"], "message": r["message"],
                       "alert_class": r["alert_class"]} for r in db.fetch_all(MESSAGES_SQL)]}


def life_safety_widget(lat: float, lng: float, risk_items: list[dict]) -> dict:
    rows = db.fetch_all(UV_AIR_SQL, {"lat": lat, "lng": lng})
    if not rows:
        return _none("자외선·미세먼지 자료가 3시간 동안 없습니다")
    names = {"uv_index": "자외선지수", "pm10": "미세먼지(PM10)", "pm25": "초미세먼지(PM2.5)"}
    hazard = {"uv_index": "uv", "pm10": "fine_dust", "pm25": "ultrafine_dust"}
    by_h = {i["hazard"]: i for i in risk_items}
    items = []
    for r in rows:
        risk = by_h.get(hazard[r["metric"]])
        items.append({"hazard": hazard[r["metric"]], "label": names[r["metric"]], "value": r["value"], "unit": r["unit"],
                      "level": risk["level"] if risk else "normal", "station_name": r["name"],
                      "observed_at": _iso(r["observed_at"])})
    return {"items": items}


# ------------------------------------------------------------------ 대피소·장소·머리 배너
def nearest_shelters(lat: float, lng: float, hazards: set[str], n: int = 3) -> list[dict]:
    feats = layers.shelters_layer(layers.GURYONGPO_BBOX)["features"]
    out = []
    for f in feats:
        p, (slng, slat) = f["properties"], f["geometry"]["coordinates"]
        if p["in_risk_area"]:
            continue
        out.append({"id": p["id"], "name": p["name"], "shelter_types": p["shelter_types"], "address": p["address"],
                    "capacity": p["capacity"], "is_accessible": p["is_accessible"], "location": {"lat": slat, "lng": slng},
                    "distance_m": round(_km(lat, lng, slat, slng) * 1000), "in_risk_area": False,
                    "unsuitable_for": p["unsuitable_for"], "unsuitable_reason": p["unsuitable_reason"]})
    out.sort(key=lambda s: (bool(set(s["unsuitable_for"]) & hazards), s["distance_m"]))
    return out[:n]


def headline(point: dict) -> Optional[dict]:
    if point["max_level_num"] < LEVEL_NUM["advisory"]:
        return None
    top = point["items"][0]
    move = top["hazard"] in ("flood", "heavy_rain", "landslide", "typhoon") and top["level_num"] >= LEVEL_NUM["warning"]
    return {"risk": top, "title": f"{top['label']} — " + ("가까운 대피소로 이동하세요" if move else "행동 요령을 확인하세요"),
            "action": "open_route" if move else "open_chat"}


def build(lat: float, lng: float, user_id: Optional[str], my_evacuation: Optional[dict]) -> dict:
    from . import users
    point = queries.point_risk(lat, lng, 300)
    levels = {i["hazard"]: i["level"] for i in point["items"]}
    places = []
    for pl in users.places(user_id) if user_id else []:
        pr = queries.point_risk(pl["location"]["lat"], pl["location"]["lng"], 0)
        places.append({"place_id": pl["id"], "label": pl["label"], "max_level": pr["max_level"],
                       "max_level_num": pr["max_level_num"]})
    worst = max([point["max_level_num"], *(p["max_level_num"] for p in places)])
    emergency = worst >= LEVEL_NUM["advisory"] or my_evacuation is not None

    stations = layers.stations_layer(layers.GURYONGPO_BBOX)["features"]
    rain_level = max((levels.get(h, "normal") for h in ("heavy_rain", "flood")), key=LEVEL_NUM.get)
    data = {
        "warnings": warnings_widget(),
        "rain": _aws_widget("rain_1h", "mm/1h", ("rain_day", "rain_12h"), rain_level),
        "water_level": water_level_widget(stations),
        "wind": _aws_widget("wind_speed", "m/s", ("wind_gust", "wind_dir"), levels.get("strong_wind", "normal")),
        "typhoon": typhoon_widget(lat, lng),
        "wave": wave_widget(levels.get("high_seas", "normal")),
        "disaster_messages": disaster_messages_widget(),
        "forecast": forecast_widget(),
        "life_safety": life_safety_widget(lat, lng, point["items"]),
    }
    hot = [w for i in point["items"] for w in HAZARD_WIDGETS.get(i["hazard"], [])]
    if data["warnings"].get("items"):
        hot.insert(0, "warnings")
    order = list(dict.fromkeys([*hot, *WIDGET_ORDER])) if emergency else WIDGET_ORDER
    widgets = [{"type": t, "emphasized": t in hot, "data": data[t]} for t in order]

    hl = ["risk_areas", "shelters"]
    if "flood" in levels or "heavy_rain" in levels:
        hl.append("manholes")
    if "landslide" in levels:
        hl.append("landslide_zones")
    return {
        "mode": "emergency" if emergency else "normal", "headline": headline(point), "point_risk": point,
        "places": places, "widgets": widgets, "highlight_layers": hl,
        "nearest_shelters": nearest_shelters(lat, lng, set(levels)), "evacuation": my_evacuation,
        "updated_at": _iso(datetime.now(KST)),
    }
