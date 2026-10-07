"""시연 모드 데이터 (2026-10-05) — 실제 센서 위치 그대로, 측정값만 시나리오 값으로 바꿔 실측과 같은 규칙으로 판정.

- 센서: DB stations (포항 DT 수위계·맨홀·강우량계·대기 센서, 구룡포 AWS)의 실제 좌표·이름
- 값  : 호우·침수 + 강풍. 포항 DT 수위계 값은 DEMO_DT (항구 저지대 침수, /internal/simulate 와 따로)
- 판정: engine.evaluate(침수·DT 강우) · hazards.evaluate_heavy_rain / evaluate_strong_wind / evaluate_landslide
        (예외 하나: 산사태 경고 범위는 위험지도 1등급 100m — demo_landslide_rules, 2026-10-07 사용자 결정)
        — 실측 판정과 같은 함수·같은 risk_rules (반경 100/150/300/500m, 15cm 기준 등)
- 저장하지 않는다: observations·risk_assessments·경고(A5)는 그대로 → 실측 모드·실제 사용자·선제 경고에 영향 없음
- 앱 시연 모드가 /api/v1/demo/* 로, 경로 서버는 요청에 demo=true 일 때 /api/v1/demo/risk/areas 를 피한다
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

from app import db
from . import engine, hazards, queries

KST = timezone(timedelta(hours=9))
SCENARIO_NAME = "호우·침수 + 강풍 (시연)"
LEVELS = ["normal", "watch", "advisory", "warning", "critical"]
UNITS = {"flood_depth": "mm", "manhole_level": "mm", "river_level": "mm", "rain_1h": "mm"}

# 포항 DT 시연 값 (external_id → 지표, 값, DT 등급). /internal/simulate heavy_rain_flood 와 따로 둔다 (2026-10-07).
# 그 값(구룡포교 주의·수협 경보 등)은 시가지 → 동쪽 대피소로 가는 유일한 해안 도로와 하천 다리를 막아 1km 대피에 5km를 돌았다.
# 산사태(호우경보 × 산사태위험지도 1·2등급 100m)는 그대로 두고, 침수를 기능이 보이게 배치 (scratchpad 측정, 시연 안내는 server/README):
#   - 환승센터 경보(300m): 항구에 있는 사람이 위험 영역 안 → 대피 안내, 지하 대피소 제외, 해안 도로로 구룡포중학교 앞까지 1.2km
#   - 하나과메기 지표면 주의(150m): 읍사무소 서쪽 → 하정축양장 앞 공터 경로가 이 구역을 피해 약 500m 돌아감 (회피 장면)
#   - 나머지는 보통(100m, 지도에만 단계 표시 — 경로·대피소 판단은 주의 이상)
DEMO_DT = {
    "10": ("flood_depth", 230, 4),     # 구룡포환승센터 지표면 — 23cm, 경보
    "7":  ("flood_depth", 120, 3),     # 하나과메기 지표면 — 12cm, 주의
    "2":  ("manhole_level", 0, 2),     # 하나과메기 스마트맨홀 — 보통 (value 는 판단 미사용)
    "11": ("flood_depth", 60, 2),      # 구룡포수협 지표면 — 보통
    "4":  ("manhole_level", 0, 2),     # 구룡포수협 스마트맨홀 — 보통
    "9":  ("flood_depth", 60, 2),      # 해양경찰서 지표면 — 보통
    "8":  ("flood_depth", 30, 2),      # 구룡포파출소 지표면 — 보통
    "3":  ("manhole_level", 0, 1),     # 로터리종합건재 스마트맨홀 — 정상
    "1":  ("river_level", 1200, 2),    # 구룡포교 하천 — 보통 (다리는 열어 둔다)
    "5":  ("rain_1h", 38.5, 4),        # 행정복지센터 강우량계 — 경보 (호우경보와 같은 단계)
}
# 구룡포 AWS 시연 값: 3시간 96mm(호우경보 기준 90mm 이상) · 12시간 168mm, 평균 16.5m/s(강풍주의보 14 이상) · 순간 24m/s, 북동풍
AWS = {"rain_1h": 41.5, "rain_3h": 96.0, "rain_12h": 168.0, "rain_day": 182.0, "rain_15m": 11.0,
       "wind_speed": 16.5, "wind_gust": 24.0, "wind_dir": 45.0, "temp": 19.2, "humidity": 97.0, "pressure_sea": 996.0}
AWS_RAIN_SERIES = [3.5, 7.0, 12.5, 19.0, 28.5, 41.5]          # 최근 6시간 시간당 강수 (마지막 = 지금)
AWS_WIND_SERIES = [8.2, 9.6, 11.4, 13.1, 15.0, 16.5]
# 대기 센서 바람: 방파제·해안은 세고 내륙은 약하게 (북동풍 40~60°)
AIR_WIND = {
    "air_10": 19.5, "air_11": 18.8, "air_14": 20.2, "air_15": 18.1, "air_16": 17.6, "air_17": 19.0, "air_6": 18.4, "air_7": 19.9,
    "air_20": 17.2, "air_21": 15.8, "air_22": 16.9, "air_23": 14.6, "air_24": 15.1,
    "air_4": 13.4, "air_5": 13.9, "air_8": 13.1, "air_12": 12.8,
    "air_1": 9.8, "air_18": 10.4, "air_19": 11.2, "air_9": 8.9, "air_13": 9.3, "air_2": 7.6, "air_3": 8.4,
}
WARNINGS = [
    {"hazard": "heavy_rain", "level": "warning", "region_name": "포항시", "headline": "[시연] 포항시 호우경보"},
    {"hazard": "strong_wind", "level": "advisory", "region_name": "포항시", "headline": "[시연] 포항시 강풍주의보"},
    {"hazard": "high_seas", "level": "warning", "region_name": "경북남부앞바다", "headline": "[시연] 경북남부앞바다 풍랑경보"},
]
WAVE_M = [3.2, 3.6, 4.1, 4.5, 4.8, 4.6, 4.2, 3.8]               # 앞으로 몇 시간 예보 파고
MESSAGES = [
    ("포항시", "긴급재난", "[시연] [포항시] 호우경보 발효. 구룡포읍 저지대·하천변 주민은 즉시 안전한 곳으로 대피하시고 지하공간 이용을 자제하세요."),
    ("행정안전부", "안전안내", "[시연] 강풍·풍랑 특보. 해안가·방파제 접근을 금지하고 선박은 결박 후 대피하세요."),
]
CACHE_S = 60.0
_cache: dict[str, tuple[float, object]] = {}


def _cached(key: str, fn):
    hit = _cache.get(key)
    if hit and time.monotonic() - hit[0] < CACHE_S:
        return hit[1]
    v = fn()
    _cache[key] = (time.monotonic(), v)
    return v


def _now() -> datetime:
    return datetime.now(KST).replace(second=0, microsecond=0)


STATIONS_SQL = """
SELECT id, source_code, external_id, name, kind, is_mountain, ST_X(geom) AS lng, ST_Y(geom) AS lat
FROM stations WHERE is_active ORDER BY id
"""
GEOM_SQL = """
SELECT t.i,
       ST_AsGeoJSON(CASE WHEN t.zone_id IS NOT NULL THEN (SELECT ST_Multi(z.geom) FROM hazard_zones z WHERE z.id = t.zone_id)
                         ELSE ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(t.lng, t.lat), 4326)::geography, t.buf)::geometry) END, 6)
         AS geojson
FROM unnest(%(i)s::int[], %(lng)s::float8[], %(lat)s::float8[], %(buf)s::float8[], %(zid)s::int[]) AS t(i, lng, lat, buf, zone_id)
"""


# ------------------------------------------------------------------ 판정 (실측과 같은 함수)
def results() -> list[engine.Result]:
    now = _now()
    stations = db.fetch_all(STATIONS_SQL)
    latest = []
    for s in stations:
        if s["source_code"] != "pohang_dt" or s["external_id"] not in DEMO_DT:
            continue
        metric, value, lv = DEMO_DT[s["external_id"]]
        latest.append({"station_id": s["id"], "external_id": s["external_id"], "name": s["name"], "kind": s["kind"],
                       "lng": s["lng"], "lat": s["lat"], "metric": metric, "value": value, "unit": UNITS[metric],
                       "source_level": lv, "observed_at": now, "simulated": True})
    out = engine.evaluate(latest, db.fetch_all(engine.RULES_SQL, {"hazards": engine.HAZARDS}))
    rules = db.fetch_all(hazards.RULES_SQL, {"hazards": hazards.HAZARDS})
    aws = next((s for s in stations if (s["source_code"], s["external_id"]) == (hazards.AWS_SOURCE, hazards.AWS_EXTERNAL_ID)), None)
    hr = hazards.evaluate_heavy_rain(AWS["rain_3h"], AWS["rain_12h"], now, rules, simulated=True)
    sw = hazards.evaluate_strong_wind(AWS["wind_speed"], AWS["wind_gust"], bool(aws and aws["is_mountain"]), now, rules, simulated=True)
    out += [r for r in (hr, sw) if r]
    # 호우 단계: DT 강우량계와 AWS 중 높은 쪽 (실측 판정과 같은 방식)
    rain_levels = [r.level for r in out if r.hazard == "heavy_rain"]
    top_rain = max(rain_levels, key=LEVELS.index) if rain_levels else "normal"
    out += hazards.evaluate_landslide(top_rain, db.fetch_all(hazards.ZONES_SQL), demo_landslide_rules(rules))
    return out


# 시연에서만 산사태 경고(호우경보) 범위를 산사태위험지도 1등급 비탈 100m 로 (사용자 결정 2026-10-07).
# 실측 규칙(risk_rules 11: 1·2등급 100m, 53km²·대피소 9곳)은 그대로 — 시연은 1등급(50km²·대피소 5곳)으로 대피소 4곳이 다시 후보가 된다.
# 단계(산사태 경고)·호우경보는 그대로이고 범위만 다르다. 지정 취약지역 100m 는 같다.
DEMO_LANDSLIDE_WARNING_AREA = "riskmap_g1_buf100"


def demo_landslide_rules(rules: list[dict]) -> list[dict]:
    """산사태 경고 규칙(11)의 위험지도 범위만 DEMO_LANDSLIDE_WARNING_AREA 로 바꾼 복사본 (원본 rules 는 그대로)"""
    out = []
    for r in rules:
        if r.get("id") == 11:
            cond = json.loads(json.dumps(hazards._cond(r)))
            for c in cond.get("all", []):
                if "within" in c:
                    c["riskmap_area"] = DEMO_LANDSLIDE_WARNING_AREA
            r = {**r, "condition": cond}
        out.append(r)
    return out


def _features() -> list[dict]:
    rs = results()
    if not rs:
        return []
    geoms = {r["i"]: r["geojson"] for r in db.fetch_all(GEOM_SQL, {
        "i": list(range(len(rs))), "lng": [r.lng for r in rs], "lat": [r.lat for r in rs],
        "buf": [float(r.buffer_m) for r in rs], "zid": [r.zone_id for r in rs]})}
    feats = []
    for i, r in enumerate(rs):
        if not geoms.get(i):
            continue
        basis = {**r.basis, "simulated": True, "demo": True}
        if "station_lat" not in basis:
            basis.update(station_lat=r.lat, station_lng=r.lng)
        row = {"id": -(i + 1), "hazard": r.hazard, "level": r.level, "label": r.label, "rule_id": r.rule_id,
               "basis": {**basis, "reason": r.reason, "observed_at": basis.get("observed_at") or _now().isoformat()}}
        g = json.loads(geoms[i])
        feats.append({"type": "Feature", "id": row["id"], "geometry": g, "properties": queries.risk_item(row),
                      "basis": row["basis"], "_bbox": _bbox_of(g)})   # basis: 침수 격자의 수심·출처용 (GeoJSON foreign member)
    feats.sort(key=lambda f: -LEVELS.index(f["properties"]["level"]))
    return feats


def _bbox_of(geom: dict) -> tuple[float, float, float, float]:
    xs, ys = [], []

    def walk(c):
        if c and isinstance(c[0], (int, float)):
            xs.append(c[0]), ys.append(c[1])
        else:
            for x in c:
                walk(x)
    walk(geom["coordinates"])
    return min(xs), min(ys), max(xs), max(ys)


def risk_areas(hazard: Optional[str] = None, min_level: Optional[str] = None,
               bbox: Optional[tuple[float, float, float, float]] = None) -> dict:
    """GET /demo/risk/areas — /risk/areas 와 같은 모양·같은 범위(bbox 생략 시 구룡포) (경로 서버가 그대로 읽는다)"""
    from app import layers
    a, b, c, d = bbox or layers.GURYONGPO_BBOX
    feats = _cached("areas", _features)
    lo = LEVELS.index(min_level or "watch")
    out = []
    for f in feats:
        if LEVELS.index(f["properties"]["level"]) < lo or (hazard is not None and f["properties"]["hazard"] != hazard):
            continue
        x0, y0, x1, y1 = f.get("_bbox") or _bbox_of(f["geometry"])
        if x1 < a or x0 > c or y1 < b or y0 > d:
            continue
        out.append({k: v for k, v in f.items() if k != "_bbox"})
    return {"type": "FeatureCollection", "features": out}


def flood_grid(bbox: tuple[float, float, float, float]) -> dict:
    """GET /demo/layers/flood_grid — 실측 침수 격자와 같은 계산(layers.flood_grid_layer)을 시연 침수 영역으로"""
    from app import layers
    zones = [{"id": f["id"], "level": f["properties"]["level"], "label": f["properties"]["label"],
              "basis": f.get("basis") or {}, "geometry": f["geometry"]}
             for f in risk_areas("flood", layers.FLOOD_GRID_MIN_LEVEL, bbox)["features"]]
    return layers.flood_grid_layer(bbox, zones=zones)


def _air_dir(ext: str) -> float:
    return 40.0 + int("".join(ch for ch in ext if ch.isdigit()) or 0) % 21    # 북동풍 40~60° (센서마다 조금씩)


def stations_layer(bbox: tuple[float, float, float, float]) -> dict:
    """GET /demo/layers/stations — 실제 관측소 위치·이름에 시연 측정값"""
    from app import layers
    ext_by_id = {s["id"]: s["external_id"] for s in db.fetch_all(STATIONS_SQL)}
    fc = layers.stations_layer(bbox)
    now = _now().isoformat()
    for f in fc["features"]:
        p = f["properties"]
        ext = ext_by_id.get(f["id"])
        metrics = dict(p.get("metrics") or {})
        if p.get("source") == "pohang_dt" and ext in DEMO_DT:
            metric, value, lv = DEMO_DT[ext]
            metrics[metric] = value
            dt = layers.DT_LEVEL.get(lv)
            p.update(metric=metric, unit=UNITS[metric], value=None if p.get("kind") == "manhole" else value, source_level=lv,
                     source_level_label=dt[1] if dt else None, level=dt[0] if dt else None)
        elif p.get("source") == hazards.AWS_SOURCE and ext == hazards.AWS_EXTERNAL_ID:
            metrics.update({k: v for k, v in AWS.items() if k != "rain_3h"})
            p.update(metric="wind_speed", unit="m/s", value=AWS["wind_speed"])
        elif p.get("source") == "pohang_dt" and ext in AIR_WIND:
            metrics.update(wind_speed=AIR_WIND[ext], wind_dir=_air_dir(ext))
        else:
            continue
        p.update(metrics=metrics, observed_at=now, stale=False, age_min=0, age_label="시연값",
                 simulated=True, value_origin="simulated")
    return fc


# ------------------------------------------------------------------ 대시보드
POINT_SQL = """
SELECT t.idx, ST_Distance(ST_SetSRID(ST_GeomFromGeoJSON(t.g), 4326)::geography,
                          ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography) AS d
FROM unnest(%(idx)s::int[], %(geoms)s::text[]) AS t(idx, g)
WHERE ST_DWithin(ST_SetSRID(ST_GeomFromGeoJSON(t.g), 4326)::geography,
                 ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography, %(radius)s)
"""


def point_risk(lat: float, lng: float, radius_m: float = 0) -> dict:
    feats = risk_areas()["features"]
    rows = db.fetch_all(POINT_SQL, {"lat": lat, "lng": lng, "radius": radius_m, "idx": list(range(len(feats))),
                                    "geoms": [json.dumps(f["geometry"]) for f in feats]}) if feats else []
    best: dict[str, dict] = {}
    for r in rows:
        item = {**feats[r["idx"]]["properties"], "distance_m": round(float(r["d"]))}
        cur = best.get(item["hazard"])
        if cur is None or item["level_num"] > cur["level_num"]:
            best[item["hazard"]] = item
    items = sorted(best.values(), key=lambda x: (-x["level_num"], x.get("distance_m", 0)))
    top = items[0]["level"] if items else "normal"
    return {"location": {"lat": lat, "lng": lng}, "max_level": top, "max_level_num": LEVELS.index(top), "items": items,
            "computed_at": _now().isoformat(), "data_stale": False, "demo": True}


def _iso(t: datetime) -> str:
    return t.isoformat(timespec="seconds")


def dashboard(lat: float, lng: float, user_id: Optional[str]) -> dict:
    """GET /demo/dashboard — 실측 /dashboard 와 같은 모양. 센서 위치는 실제, 값은 시나리오"""
    from app import layers, widgets, users
    now = _now()
    point = point_risk(lat, lng, 300)
    levels = {i["hazard"]: i["level"] for i in point["items"]}
    places = []
    for pl in users.places(user_id) if user_id else []:
        pr = point_risk(pl["location"]["lat"], pl["location"]["lng"], 0)
        places.append({"place_id": pl["id"], "label": pl["label"], "max_level": pr["max_level"], "max_level_num": pr["max_level_num"]})

    st = stations_layer(layers.GURYONGPO_BBOX)["features"]
    rain_level = max((levels.get(h, "normal") for h in ("heavy_rain", "flood")), key=LEVELS.index)
    hours = [now - timedelta(hours=5 - k) for k in range(6)]
    data = {
        "warnings": {"items": [{"label": w["headline"], "hazard": w["hazard"], "level": w["level"],
                                "region_name": w["region_name"], "issued_at": _iso(now - timedelta(minutes=90))} for w in WARNINGS]},
        "rain": {"station_name": "구룡포 AWS (기상청) · 시연값", "value": AWS["rain_1h"], "unit": "mm/1h", "observed_at": _iso(now),
                 "level": rain_level, "rain_day": AWS["rain_day"], "rain_12h": AWS["rain_12h"],
                 "series": [{"t": _iso(t), "v": v} for t, v in zip(hours, AWS_RAIN_SERIES)]},
        "water_level": widgets.water_level_widget(st),
        "wind": {"station_name": "구룡포 AWS (기상청) · 시연값", "value": AWS["wind_speed"], "unit": "m/s", "observed_at": _iso(now),
                 "level": levels.get("strong_wind", "normal"), "wind_gust": AWS["wind_gust"], "wind_dir": AWS["wind_dir"],
                 "series": [{"t": _iso(t), "v": v} for t, v in zip(hours, AWS_WIND_SERIES)]},
        "typhoon": widgets.typhoon_widget(lat, lng),
        "wave": {"station_name": "구룡포항 앞바다 · 시연 예보", "value": WAVE_M[0], "unit": "m", "observed_at": _iso(now), "level": "warning",
                 "is_forecast": True, "series": [{"t": _iso(now + timedelta(hours=k * 3)), "v": v} for k, v in enumerate(WAVE_M)]},
        "disaster_messages": {"items": [{"sent_at": _iso(now - timedelta(minutes=70 - 30 * k)), "sender": s, "alert_class": c, "message": m}
                                        for k, (s, c, m) in enumerate(MESSAGES)]},
        "forecast": {"source": "시연 예보 (구룡포읍)", "slots": [
            {"t": _iso(now + timedelta(hours=k + 1)), "pop": max(30, 95 - k * 6), "pty": "비" if k < 8 else "없음",
             "pcp_mm": max(0.0, 35.0 - k * 4), "tmp": 19 - (k % 3) * 0.5, "wsd": max(6.0, 17.5 - k)} for k in range(12)]},
        "life_safety": widgets.life_safety_widget(lat, lng, point["items"]),
    }
    hot = [w for i in point["items"] for w in widgets.HAZARD_WIDGETS.get(i["hazard"], [])]
    hot.insert(0, "warnings")
    order = list(dict.fromkeys([*hot, *widgets.WIDGET_ORDER]))
    shelters = widgets.nearest_shelters(lat, lng, set(levels), n=12)
    in_area = _in_demo_areas([(s["location"]["lat"], s["location"]["lng"]) for s in shelters])
    shelters = [s for s, bad in zip(shelters, in_area) if not bad][:3]
    hl = ["risk_areas", "shelters"] + (["manholes"] if "flood" in levels or "heavy_rain" in levels else []) \
        + (["landslide_zones"] if "landslide" in levels else [])
    return {"mode": "emergency", "headline": widgets.headline(point), "point_risk": point, "places": places,
            "widgets": [{"type": t, "emphasized": t in hot, "data": data[t]} for t in order],
            "highlight_layers": hl, "nearest_shelters": shelters, "evacuation": None,
            "updated_at": _iso(now), "demo": {"scenario": SCENARIO_NAME,
                                             "note": "센서 위치는 실제, 측정값은 시연용 가상값. 실제 판정·경고에는 쓰지 않음"}}


IN_AREAS_SQL = """
SELECT t.k, EXISTS (SELECT 1 FROM unnest(%(geoms)s::text[]) g
                    WHERE ST_Intersects(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326), ST_SetSRID(ST_MakePoint(t.lng, t.lat), 4326))) AS hit
FROM unnest(%(k)s::int[], %(lat)s::float8[], %(lng)s::float8[]) AS t(k, lat, lng)
"""


def _in_demo_areas(points: list[tuple[float, float]]) -> list[bool]:
    feats = [f for f in risk_areas(min_level="advisory")["features"] if f["properties"]["hazard"] in ("flood", "landslide")]
    if not points or not feats:
        return [False] * len(points)
    rows = db.fetch_all(IN_AREAS_SQL, {"k": list(range(len(points))), "lat": [p[0] for p in points], "lng": [p[1] for p in points],
                                       "geoms": [json.dumps(f["geometry"]) for f in feats]})
    hit = {r["k"]: bool(r["hit"]) for r in rows}
    return [hit.get(k, False) for k in range(len(points))]
