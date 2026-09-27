"""위험도 조회 — /risk (한 지점), /risk/areas (지도 영역). 명세 RiskItem 형식으로 반환"""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from typing import Optional

from app import db
from .levels import LEVEL_NUM, LEVELS

KST = timezone(timedelta(hours=9))
STALE_MIN = 30        # 판정 엔진이 이보다 오래 안 돌았으면 data_stale=true


def _iso(t) -> Optional[str]:
    if t is None:
        return None
    if isinstance(t, str):
        t = datetime.fromisoformat(t)
    return t.astimezone(KST).isoformat(timespec="seconds")


def _basis(v) -> dict:
    return v if isinstance(v, dict) else json.loads(v or "{}")


def risk_item(row: dict) -> dict:
    """risk_assessments 행 → RiskItem"""
    b = _basis(row.get("basis"))
    lat, lng = b.get("station_lat"), b.get("station_lng")
    item = {
        "hazard": row["hazard"], "level": row["level"], "level_num": LEVEL_NUM[row["level"]], "label": row["label"],
        "reason": b.get("reason"),
        "location": {"lat": lat, "lng": lng} if lat is not None else None,
        "area_id": row["id"], "rule_id": row.get("rule_id"), "observed_at": _iso(b.get("observed_at")),
    }
    if item["location"] is None:
        item.pop("location")
    if b.get("simulated"):
        item["simulated"] = True
    if row.get("distance_m") is not None:
        item["distance_m"] = round(float(row["distance_m"]))
    return item


POINT_SQL = """
SELECT DISTINCT ON (ra.hazard) ra.id, ra.hazard::text AS hazard, ra.level::text AS level, ra.label, ra.rule_id,
       ra.basis, ra.computed_at, ST_Distance(ra.area::geography, p.pt::geography) AS distance_m,
       -- 같은 단계의 영역이 여럿이면 원인 관측소가 가장 가까운 것 (그 지점의 사정을 가장 잘 설명)
       ST_Distance(ST_SetSRID(ST_MakePoint((ra.basis->>'station_lng')::float8, (ra.basis->>'station_lat')::float8), 4326)::geography,
                   p.pt::geography) AS source_distance_m
FROM risk_assessments ra, (SELECT ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326) AS pt) p
WHERE ra.valid_to IS NULL AND ST_DWithin(ra.area::geography, p.pt::geography, %(radius_m)s)
ORDER BY ra.hazard, ra.level DESC, distance_m, source_distance_m NULLS LAST, ra.id
"""
LAST_RUN_SQL = """
SELECT max(finished_at) AS t FROM ingest_runs WHERE source_code = 'risk' AND status = 'success'
"""


def point_risk(lat: float, lng: float, radius_m: float = 0) -> dict:
    """좌표가 포함된 (radius_m > 0 이면 그 거리 안에 있는) 현재 위험 영역을 재난별 최고 단계로"""
    rows = db.fetch_all(POINT_SQL, {"lat": lat, "lng": lng, "radius_m": radius_m})
    items = sorted((risk_item(r) for r in rows), key=lambda x: (-x["level_num"], x.get("distance_m", 0), x["hazard"]))
    last = (db.fetch_one(LAST_RUN_SQL) or {}).get("t")
    now = datetime.now(KST)
    top = items[0]["level"] if items else "normal"
    return {
        "location": {"lat": lat, "lng": lng}, "max_level": top, "max_level_num": LEVEL_NUM[top], "items": items,
        "computed_at": _iso(last) or _iso(now),
        # 판정이 30분 넘게 안 돌았으면 '정상'이 실제로 정상인지 알 수 없음 → 앱이 "정보 지연" 표시
        "data_stale": last is None or now - (last if not isinstance(last, str) else datetime.fromisoformat(last)) > timedelta(minutes=STALE_MIN),
    }


AREAS_SQL = """
SELECT ra.id, ra.hazard::text AS hazard, ra.level::text AS level, ra.label, ra.rule_id, ra.basis,
       ST_AsGeoJSON(ra.area, 6) AS geojson
FROM risk_assessments ra
WHERE ra.valid_to IS NULL
  AND (%(hazard)s::text IS NULL OR ra.hazard::text = %(hazard)s::text)
  AND ra.level >= %(min_level)s::risk_level
  AND ST_Intersects(ra.area, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))
ORDER BY ra.level DESC, ra.id
"""


def areas(hazard: Optional[str], min_level: Optional[str], bbox: tuple[float, float, float, float]) -> dict:
    rows = db.fetch_all(AREAS_SQL, {"hazard": hazard, "min_level": min_level or LEVELS[1], **dict(zip("abcd", bbox))})
    return {"type": "FeatureCollection", "features": [
        {"type": "Feature", "id": r["id"], "geometry": json.loads(r["geojson"]), "properties": risk_item(r)} for r in rows]}
