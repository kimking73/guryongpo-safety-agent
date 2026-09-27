"""지도 레이어 GeoJSON — 실데이터가 있는 레이어는 DB, 나머지는 목업

실데이터: stations (관측소 + 최신값), landslide_zones (산사태 취약지역)
목업    : shelters, medical, flood_zones, coastal_zones, manholes, risk_areas (A3·A7 에서 교체)
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from . import db

KST = timezone(timedelta(hours=9))
GURYONGPO_BBOX = (129.50, 35.93, 129.60, 36.05)      # 생략 시 구룡포 전체 (minLng,minLat,maxLng,maxLat)

# 관측소 종류별 대표 지표 (지도 마커에 표시할 값)
PRIMARY_METRIC = {"manhole": "manhole_level", "road_flood": "flood_depth", "river_level": "river_level",
                  "rain_gauge": "rain_1h", "air": "pm10", "uv": "uv_index", "weather": "wind_speed",
                  "wave": "wave_height", "tide": "tide_level"}
DT_LEVEL = {1: ("normal", "정상"), 2: ("watch", "보통"), 3: ("advisory", "주의"), 4: ("warning", "경보"), 5: ("critical", "위험")}
FRESH_MIN = {"air": 60, "uv": 90}                     # 이보다 오래된 값은 stale=true (위험 판단 미사용)
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
            "stale": bool(obs_at and r["kind"] in FRESH_MIN and now - obs_at > timedelta(minutes=FRESH_MIN[r["kind"]])),
            "metrics": {k: v["value"] for k, v in ms.items() if k not in ("battery",)},
            "simulated": bool(p and p.get("simulated")),
        }
        features.append({"type": "Feature", "id": sid,
                         "geometry": {"type": "Point", "coordinates": [r["lng"], r["lat"]]}, "properties": props})
    return {"type": "FeatureCollection", "features": features}


LANDSLIDE_SQL = """
SELECT id, name, grade, meta, ST_AsGeoJSON(geom) AS geojson
FROM hazard_zones
WHERE hazard = 'landslide' AND ST_Intersects(geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY id
"""


def landslide_layer(bbox: tuple[float, float, float, float]) -> dict:
    feats = []
    for r in db.fetch_all(LANDSLIDE_SQL, dict(zip("abcd", bbox))):
        meta = r["meta"] if isinstance(r["meta"], dict) else json.loads(r["meta"] or "{}")
        feats.append({"type": "Feature", "id": r["id"], "geometry": json.loads(r["geojson"]),
                      "properties": {"name": r["name"], "hazard": "landslide", "grade": r["grade"],
                                     "reason": meta.get("reason"), "area_m2": meta.get("area_m2"),
                                     "shelter_distance_m": meta.get("shelter_distance_m")}})
    return {"type": "FeatureCollection", "features": feats}
