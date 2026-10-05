"""지도 레이어 GeoJSON — 실데이터가 있는 레이어는 DB, 나머지는 목업

실데이터: stations (관측소 + 최신값), landslide_zones (산사태 취약지역), risk_areas (A3 판정 결과 — risk.queries),
         shelters · medical · manholes (A7 loader 가 적재한 정적 데이터)
위험지역 고정 영역은 산사태 취약지역만 사용 (침수는 수위계 기반 실시간 판정 영역 risk_areas 로 표시)
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from . import db
from risk.freshness import freshness

KST = timezone(timedelta(hours=9))
GURYONGPO_BBOX = (129.50, 35.93, 129.60, 36.05)      # 생략 시 구룡포 전체 (minLng,minLat,maxLng,maxLat)

# 관측소 종류별 대표 지표 (지도 마커에 표시할 값)
PRIMARY_METRIC = {"manhole": "manhole_level", "road_flood": "flood_depth", "river_level": "river_level",
                  "rain_gauge": "rain_1h", "air": "pm10", "uv": "uv_index", "weather": "wind_speed",
                  "wave": "wave_height", "tide": "tide_level"}
DT_LEVEL = {1: ("normal", "정상"), 2: ("watch", "보통"), 3: ("advisory", "주의"), 4: ("warning", "경보"), 5: ("critical", "위험")}
# 오래된 자료 판정은 risk/freshness.py 한 곳에서 (표시는 최신값 + 경과 시간, 유효 시간 넘으면 stale)
KMA_GRID_PRIMARY = "temp"                             # 초단기실황 격자는 풍속보다 기온이 대표값


def parse_bbox(bbox: str | None) -> tuple[float, float, float, float]:
    if not bbox:
        return GURYONGPO_BBOX
    try:
        a = tuple(float(x) for x in bbox.split(","))
    except ValueError:
        a = ()
    if len(a) != 4 or not (a[0] < a[2] and a[1] < a[3]):
        from .errors import ApiError
        raise ApiError("VALIDATION_ERROR", "지도 범위(bbox) 형식이 올바르지 않습니다.",
                       detail="bbox=minLng,minLat,maxLng,maxLat")
    return a  # type: ignore[return-value]


# 관측소별 지표 최신값. 시연 모의값(quality='simulated', 6시간 이내)이 있으면 실측보다 우선 — 판정 엔진과 같은 규칙
# 최근 3일 값만 봄 (갱신이 멈춘 장비는 값 없이 위치만 표시)
STATIONS_SQL = """
SELECT s.id, s.source_code, s.external_id, s.name, s.kind, ST_X(s.geom) AS lng, ST_Y(s.geom) AS lat,
       o.metric, o.value, o.unit, o.source_level, o.observed_at, o.simulated
FROM stations s
LEFT JOIN LATERAL (
  SELECT DISTINCT ON (x.metric) x.metric, x.value, x.unit, x.source_level, x.observed_at,
         (x.quality IS NOT DISTINCT FROM 'simulated') AS simulated
  FROM observations x
  WHERE x.station_id = s.id AND x.observed_at > now() - interval '3 days'
    AND (x.quality IS DISTINCT FROM 'simulated' OR x.observed_at > now() - interval '6 hours')
  ORDER BY x.metric, (x.quality IS NOT DISTINCT FROM 'simulated') DESC, x.observed_at DESC
) o ON true
WHERE s.is_active AND ST_Intersects(s.geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY s.id, o.metric
"""


def _iso(t):
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    return t.astimezone(KST).isoformat(timespec="seconds") if t else None


def _fresh(obs_at, r, now) -> dict:
    f = freshness(obs_at, r["source_code"], r["kind"], r["external_id"], now)
    # stale: 유효 시간을 넘은 값 (앱은 회색 처리·"오래된 자료", 판단에는 미사용). age_label 은 그대로 표시용
    return {"stale": bool(obs_at) and f["stale"], "age_min": f["age_min"], "age_label": f["label"]}


def stations_layer(bbox: tuple[float, float, float, float], now: datetime | None = None) -> dict:
    now = now or datetime.now(KST)
    rows = db.fetch_all(STATIONS_SQL, dict(zip("abcd", bbox)))
    by_id: dict[int, dict] = {}
    for r in rows:
        f = by_id.setdefault(r["id"], {"row": r, "metrics": {}})
        if r["metric"]:
            f["metrics"][r["metric"]] = r
    features = []
    for sid, f in by_id.items():
        r, ms = f["row"], f["metrics"]
        primary = KMA_GRID_PRIMARY if r["external_id"].startswith("grid_") else PRIMARY_METRIC.get(r["kind"])
        p = ms.get(primary) or (next(iter(ms.values())) if ms else None)
        lv = DT_LEVEL.get(p["source_level"]) if p and p["source_level"] is not None else None
        obs_at = p["observed_at"] if p else None
        if isinstance(obs_at, str):
            obs_at = datetime.fromisoformat(obs_at)
        props = {
            "name": r["name"], "kind": r["kind"], "source": r["source_code"],
            "metric": p["metric"] if p else primary, "unit": p["unit"] if p else None,
            # 스마트맨홀 value 는 판단에 쓰지 않음 (level 만) → 목업과 같이 null
            "value": None if (not p or r["kind"] == "manhole") else p["value"],
            "source_level": p["source_level"] if p else None,
            "source_level_label": lv[1] if lv else None,
            "level": lv[0] if lv else None,          # 우리 위험 단계는 risk engine(A3) 연결 후 채움 — 지금은 포항 DT 등급만
            "observed_at": _iso(obs_at),
            "observed_label": "수집" if r["kind"] in ("manhole", "road_flood", "river_level", "rain_gauge") else "측정",
            **_fresh(obs_at, r, now),
            "metrics": {k: v["value"] for k, v in ms.items() if k not in ("battery",)},
            "simulated": bool(p and p.get("simulated")),
            "value_origin": "unavailable" if not p else ("simulated" if p.get("simulated") else "observed"),
        }
        features.append({"type": "Feature", "id": sid,
                         "geometry": {"type": "Point", "coordinates": [r["lng"], r["lat"]]}, "properties": props})
    return {"type": "FeatureCollection", "features": features}


LANDSLIDE_SQL = """
SELECT id, source_code, name, grade, meta, ST_AsGeoJSON(geom) AS geojson
FROM hazard_zones
WHERE hazard = 'landslide' AND COALESCE(meta->>'role', '') <> 'trigger_area'   -- 판정용 100m 범위는 risk_areas 로만 보임
  AND ST_Intersects(geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY id
"""


def landslide_layer(bbox: tuple[float, float, float, float]) -> dict:
    feats = []
    for r in db.fetch_all(LANDSLIDE_SQL, dict(zip("abcd", bbox))):
        meta = r["meta"] if isinstance(r["meta"], dict) else json.loads(r["meta"] or "{}")
        feats.append({"type": "Feature", "id": r["id"], "geometry": json.loads(r["geojson"]),
                      "properties": {"name": r["name"], "hazard": "landslide", "grade": r["grade"],
                                     "kind": "riskmap" if meta.get("role") == "display" else "designated",
                                     "data_kind": "official_risk_map" if meta.get("role") == "display" else "designated_vulnerable_area",
                                     "data_label": "산림청 산사태 위험지도 등급 · 현재 발생/예보 아님" if meta.get("role") == "display" else "산사태 취약지역 지정 자료 · 현재 발생/예보 아님",
                                     "source": meta.get("source") or ("산림청 산사태 위험지도" if meta.get("role") == "display" else "공공데이터포털 · 경상북도 포항시 산사태 취약지역 현황"),
                                     "source_code": r.get("source_code") or ("safemap" if meta.get("role") == "display" else "datagokr"),
                                     "source_url": "https://sansatai.forest.go.kr/" if meta.get("role") == "display" else "https://www.data.go.kr/",
                                     "is_example": False,
                                     "reason": meta.get("reason"), "area_m2": meta.get("area_m2"),
                                     "shelter_distance_m": meta.get("shelter_distance_m")}})
    return {"type": "FeatureCollection", "features": feats}


# Risk assessments are produced by the server from an observed station or
# another explicit assessment. Tiling only discretizes those assessed areas;
# it does not spread point observations into unassessed cells.
# 침수 격자 (2026-10-05 변경): 경로 서버(GraphHopper)가 피하는 침수 지역과 똑같이.
#   경로 서버는 GET /risk/areas?min_level=advisory 의 침수·산사태 영역을 피한다 (route/guardian_route/hazards.py
#   RiskAreaHazardSource). 그래서 격자도 같은 영역(지금 유효한 침수 판정, 주의 이상)만 쓰고, 약 100m 칸(FLOOD_GRID_STEP)을
#   영역 모양대로 잘라 보낸다 — 칸을 모두 합치면 경로가 피하는 침수 영역과 같다. 한 칸에 여러 영역이 걸치면 가장 높은 단계.
#   (예전: 0.004° 큰 칸이 관심(watch) 이상 영역에 조금만 걸쳐도 칸 전체를 칠해 실제 회피 영역보다 넓었다)
FLOOD_GRID_STEP = 0.001
FLOOD_GRID_MIN_LEVEL = "advisory"     # route/guardian_route/hazards.py MIN_LEVEL 과 같아야 한다
FLOOD_GRID_SQL = """
WITH env AS (
  SELECT ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326) AS g, %(step)s::float8 AS step
), z AS (
  SELECT ra.id, ra.level, ra.label, ra.basis, ra.computed_at, ra.area
  FROM risk_assessments ra, env
  WHERE ra.valid_to IS NULL AND ra.hazard = 'flood' AND ra.level >= %(min_level)s::risk_level
    AND ST_Intersects(ra.area, env.g)
), cells AS (
  SELECT DISTINCT ix, iy
  FROM z, env,
       generate_series(floor(ST_XMin(z.area) / env.step)::int, floor(ST_XMax(z.area) / env.step)::int) AS ix,
       generate_series(floor(ST_YMin(z.area) / env.step)::int, floor(ST_YMax(z.area) / env.step)::int) AS iy
), pieces AS (
  SELECT c.ix, c.iy, z.id, z.level, z.label, z.basis, z.computed_at,
         ST_CollectionExtract(ST_Intersection(
           ST_MakeEnvelope(c.ix * env.step, c.iy * env.step, (c.ix + 1) * env.step, (c.iy + 1) * env.step, 4326), z.area), 3) AS geom
  FROM cells c, env, z
  WHERE ST_Intersects(ST_MakeEnvelope(c.ix * env.step, c.iy * env.step, (c.ix + 1) * env.step, (c.iy + 1) * env.step, 4326), z.area)
    AND ST_Intersects(ST_MakeEnvelope(c.ix * env.step, c.iy * env.step, (c.ix + 1) * env.step, (c.iy + 1) * env.step, 4326), env.g)
), shape AS (
  SELECT ix, iy, ST_Union(geom) AS geom FROM pieces WHERE NOT ST_IsEmpty(geom) GROUP BY ix, iy
), top AS (
  SELECT DISTINCT ON (ix, iy) ix, iy, id, level::text AS level, label, basis
  FROM pieces ORDER BY ix, iy, level DESC, computed_at DESC, id DESC
)
SELECT top.ix || '_' || top.iy AS cell_id, top.id, top.level, top.label, top.basis, ST_AsGeoJSON(shape.geom, 6) AS geojson
FROM top JOIN shape USING (ix, iy)
ORDER BY top.iy, top.ix
"""


# 시연 모드(risk/demo.py): 같은 격자 계산을 risk_assessments 대신 넘겨받은 영역(GeoJSON)으로
FLOOD_GRID_ZONES_CTE = """z AS (
  SELECT (e->>'id')::bigint AS id, (e->>'level')::risk_level AS level, e->>'label' AS label, (e->'basis')::jsonb AS basis,
         now() AS computed_at, ST_SetSRID(ST_GeomFromGeoJSON(e->>'geometry'), 4326) AS area
  FROM json_array_elements(%(zones)s::json) AS e, env
  WHERE (e->>'level')::risk_level >= %(min_level)s::risk_level
    AND ST_Intersects(ST_SetSRID(ST_GeomFromGeoJSON(e->>'geometry'), 4326), env.g)
), cells AS ("""


def flood_grid_layer(bbox: tuple[float, float, float, float], zones: list[dict] | None = None) -> dict:
    features = []
    params = {**dict(zip("abcd", bbox)), "step": FLOOD_GRID_STEP, "min_level": FLOOD_GRID_MIN_LEVEL}
    sql = FLOOD_GRID_SQL
    if zones is not None:
        if not zones:
            return {"type": "FeatureCollection", "features": []}
        start, end = sql.index("z AS ("), sql.index("cells AS (")
        sql = sql[:start] + FLOOD_GRID_ZONES_CTE + sql[end + len("cells AS ("):]
        params["zones"] = json.dumps([{**z, "geometry": json.dumps(z["geometry"])} for z in zones], ensure_ascii=False, default=str)
    for r in db.fetch_all(sql, params):
        basis = r["basis"] if isinstance(r["basis"], dict) else json.loads(r["basis"] or "{}")
        value = basis.get("value")
        depth_cm = None
        if basis.get("metric") == "flood_depth" and value is not None:
            try:
                depth_cm = float(value) / 10 if basis.get("unit") == "mm" else float(value)
            except (TypeError, ValueError):
                depth_cm = None
        features.append({
            "type": "Feature", "id": r.get("cell_id") or r["id"], "geometry": json.loads(r["geojson"]),
            "properties": {
                "hazard": "flood", "level": r["level"], "label": r["label"], "area_id": r["id"],
                "observed_depth_cm": depth_cm, "observed_at": basis.get("observed_at"),
                "source": basis.get("station_name") or basis.get("source") or "위험 판정 자료",
                "simulated": bool(basis.get("simulated")),
                "data_status": "simulated" if basis.get("simulated") else "assessed",
            },
        })
    return {"type": "FeatureCollection", "features": features}


# ---------------------------------------------------------------- 정적 시설 (A7 loader 가 적재)
POHANG_BBOX = (129.30, 35.90, 129.62, 36.10)          # 구룡포 안에 응급의료기관이 없어 의료시설은 bbox 생략 시 포항 전체

# in_risk_area: 대피소 자체가 현재 유효한 위험 영역(risk_assessments, 주의 이상) 안이면 true → 앱·경로 안내에서 제외
# landslide_g1_m: 산사태위험지도 1등급 비탈 100m 안이면 그 거리(m) → 산사태 때 비추천 (unsuitable_for)
#   100m 범위(riskmap_g1_buf100, 09_seed)로 먼저 거른 뒤에만 1등급 폴리곤과 거리 계산 (큰 폴리곤이라 전부 계산하면 느림)
SHELTERS_SQL = """
SELECT s.id, s.name, s.shelter_types, s.address, s.capacity, s.phone, s.is_indoor, s.is_accessible,
       ST_X(s.geom) AS lng, ST_Y(s.geom) AS lat,
       EXISTS (SELECT 1 FROM risk_assessments ra
               WHERE ra.valid_to IS NULL AND ra.level >= 'advisory' AND ST_Intersects(ra.area, s.geom)) AS in_risk_area,
       (SELECT round(ST_Distance(s.geom::geography, g1.geom::geography))
        FROM hazard_zones b JOIN hazard_zones g1 ON g1.hazard = 'landslide' AND g1.external_id = 'riskmap_g1'
        WHERE b.hazard = 'landslide' AND b.external_id = 'riskmap_g1_buf100' AND ST_Intersects(b.geom, s.geom)) AS landslide_g1_m
FROM shelters s
WHERE s.is_open AND ST_Intersects(s.geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY s.id
"""

# er: 응급실 실시간 가용병상 최신값 (국립중앙의료원, 10분 수집 nmc.er_beds) — 하루 지난 값은 없는 것으로
MEDICAL_SQL = """
SELECT m.id, m.name, m.kind, m.address, m.phone, m.meta, ST_X(m.geom) AS lng, ST_Y(m.geom) AS lat,
       e.er_beds, e.ambulance, e.observed_at AS er_observed_at
FROM medical_facilities m
LEFT JOIN LATERAL (
  SELECT er_beds, ambulance, observed_at FROM er_availability x
  WHERE x.facility_id = m.id AND x.observed_at > now() - interval '1 day'
  ORDER BY observed_at DESC LIMIT 1
) e ON true
WHERE ST_Intersects(m.geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY m.id
"""
ER_VALID_MIN = 40          # 수집기 stale_after_min 과 같음 (10분 수집 × 4)

MANHOLES_SQL = """
SELECT m.id, m.source_code, m.external_id, m.kind, ST_X(m.geom) AS lng, ST_Y(m.geom) AS lat, st.name
FROM manholes m
LEFT JOIN stations st ON st.source_code = m.source_code AND st.external_id = m.external_id
WHERE ST_Intersects(m.geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY m.id
"""


def _point(r: dict, props: dict) -> dict:
    return {"type": "Feature", "id": r["id"], "geometry": {"type": "Point", "coordinates": [r["lng"], r["lat"]]},
            "properties": props}


def shelters_layer(bbox: tuple[float, float, float, float]) -> dict:
    feats = [_point(r, {"id": r["id"], "name": r["name"], "shelter_types": list(r["shelter_types"] or []),
                        "address": r["address"], "capacity": r["capacity"], "phone": r["phone"],
                        "is_indoor": r["is_indoor"], "is_accessible": r["is_accessible"],
                        "in_risk_area": bool(r["in_risk_area"]), **_unsuitable(r.get("landslide_g1_m"))})
             for r in db.fetch_all(SHELTERS_SQL, dict(zip("abcd", bbox)))]
    return {"type": "FeatureCollection", "features": feats}


def _unsuitable(landslide_g1_m) -> dict:
    if landslide_g1_m is None:
        return {"unsuitable_for": [], "unsuitable_reason": None}
    return {"unsuitable_for": ["landslide"], "unsuitable_reason": f"산사태위험지도 1등급 비탈 {int(landslide_g1_m)}m"}


def _er(r: dict, now: datetime) -> dict | None:
    t = r.get("er_observed_at")
    if t is None:
        return None
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    age = (now - t).total_seconds() / 60
    return {"beds": r.get("er_beds"), "ambulance": r.get("ambulance"), "observed_at": _iso(t), "stale": age > ER_VALID_MIN}


def medical_layer(bbox: tuple[float, float, float, float], now: datetime | None = None) -> dict:
    now = now or datetime.now(KST)
    feats = []
    for r in db.fetch_all(MEDICAL_SQL, dict(zip("abcd", bbox))):
        meta = r["meta"] if isinstance(r["meta"], dict) else json.loads(r["meta"] or "{}")
        feats.append(_point(r, {"id": r["id"], "name": r["name"], "kind": r["kind"], "address": r["address"],
                                "phone": r["phone"], "er_phone": meta.get("er_phone"),
                                "emergency_class": meta.get("emergency_class"), "er": _er(r, now)}))
    return {"type": "FeatureCollection", "features": feats}


def manholes_layer(bbox: tuple[float, float, float, float]) -> dict:
    feats = [_point(r, {"id": r["id"], "kind": r["kind"], "name": r["name"], "source": r["source_code"]})
             for r in db.fetch_all(MANHOLES_SQL, dict(zip("abcd", bbox)))]
    return {"type": "FeatureCollection", "features": feats}
