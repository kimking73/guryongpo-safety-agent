"""침수 판정 (A3) — 판정 규칙은 DB 없이, /risk 응답 형식은 FakeDB 로"""
from datetime import datetime, timedelta, timezone

import pytest

KST = timezone(timedelta(hours=9))
NOW = datetime(2026, 10, 5, 14, 27, tzinfo=KST)

# seed.sql 과 같은 기준 (id·조건)
RULES = [
    {"id": 9, "hazard": "flood", "level": "advisory", "label": "침수 발생", "metric": "flood_depth", "operator": ">=",
     "threshold": 150, "threshold_max": None, "condition": {"station_kind": "road_flood", "buffer_m": 150}},
    *[{"id": 19 + n, "hazard": "flood", "level": lv, "label": f"침수 {ko} (포항 DT {n}단계)", "metric": None,
       "operator": "composite", "threshold": None, "threshold_max": None,
       "condition": {"station_kind": ["manhole", "road_flood", "river_level"], "source_level": {"=": n}, "buffer_m": buf}}
      for n, lv, ko, buf in ((2, "watch", "보통", 100), (3, "advisory", "주의", 150), (4, "warning", "경보", 300), (5, "critical", "위험", 500))],
    *[{"id": 23 + n, "hazard": "heavy_rain", "level": lv, "label": f"강우 {ko} (포항 DT {n}단계)", "metric": None,
       "operator": "composite", "threshold": None, "threshold_max": None,
       "condition": {"station_kind": "rain_gauge", "source_level": {"=": n}}}
      for n, lv, ko in ((2, "watch", "보통"), (3, "advisory", "주의"), (4, "warning", "경보"), (5, "critical", "위험"))],
]


def obs(sid, kind, metric, value, level, name="관측소"):
    return {"station_id": sid, "external_id": str(sid), "name": name, "kind": kind, "lng": 129.556, "lat": 35.990,
            "metric": metric, "value": value, "unit": "mm", "source_level": level, "observed_at": NOW, "simulated": False}


def one(latest):
    from risk.engine import evaluate
    res = evaluate(latest, RULES)
    assert len(res) <= 1
    return res[0] if res else None


def test_dt_level_wins_over_depth_rule():
    r = one([obs(10, "road_flood", "flood_depth", 230, 4, "구룡포환승센터_지표면 수위계")])
    assert (r.hazard, r.level, r.rule_id, r.buffer_m) == ("flood", "warning", 23, 300)
    assert r.label == "침수 경보"
    assert "침수심 230mm (기준 150mm)" in r.reason and "4단계(경보)" in r.reason and "구룡포환승센터 지표면" in r.reason


def test_depth_rule_preferred_on_same_level():
    r = one([obs(11, "road_flood", "flood_depth", 170, 3)])
    assert (r.level, r.rule_id) == ("advisory", 9)


def test_depth_rule_alone_when_dt_level_normal():
    r = one([obs(11, "road_flood", "flood_depth", 160, 1)])
    assert (r.level, r.rule_id, r.buffer_m) == ("advisory", 9, 150)


def test_normal_gives_nothing():
    assert one([obs(7, "road_flood", "flood_depth", 0, 1)]) is None
    assert one([obs(1, "river_level", "river_level", 900, 1)]) is None


def test_manhole_uses_level_only():
    assert one([obs(2, "manhole", "manhole_level", 99999, 1)]) is None      # value 가 커도 등급 정상이면 없음
    assert one([obs(4, "manhole", "manhole_level", 0, 4)]).level == "warning"


def test_rain_gauge_covers_guryongpo():
    from risk.levels import GURYONGPO_CENTER, GURYONGPO_RADIUS_M
    r = one([obs(5, "rain_gauge", "rain_1h", 38.5, 4)])
    assert (r.hazard, r.level, r.rule_id) == ("heavy_rain", "warning", 27)
    assert (r.lng, r.lat) == GURYONGPO_CENTER and r.buffer_m == GURYONGPO_RADIUS_M
    assert "시간당 38.5mm" in r.reason


def test_only_primary_metric_counts():
    assert one([obs(21, "road_flood", "temp", 999, 5)]) is None


def test_simulated_marked():
    o = obs(10, "road_flood", "flood_depth", 230, 4)
    o["simulated"] = True
    r = one([o])
    assert r.reason.endswith("(모의)") and r.basis["simulated"] is True


# ------------------------------------------------------------------ API
def area_row(i, hazard, level, label, reason, lat=35.9907, lng=129.5561, dist=0.0):
    return {"id": i, "hazard": hazard, "level": level, "label": label, "rule_id": 23, "distance_m": dist,
            "computed_at": NOW, "basis": {"reason": reason, "station_lat": lat, "station_lng": lng,
                                          "observed_at": NOW.isoformat(), "simulated": False},
            "geojson": '{"type":"MultiPolygon","coordinates":[[[[129.55,35.99],[129.56,35.99],[129.56,36.0],[129.55,35.99]]]]}'}


def test_point_risk_api(client, fake_db):
    fake_db.rows["ST_DWithin(ra.area"] = [
        area_row(3, "heavy_rain", "watch", "강우 보통", "강우량계"),
        area_row(7, "flood", "warning", "침수 경보", "환승센터 230mm")]
    fake_db.rows["source_code = 'risk'"] = [{"t": datetime.now(KST)}]
    body = client.get("/api/v1/risk", params={"lat": 35.9907, "lng": 129.5561}).json()
    assert body["max_level"] == "warning" and body["max_level_num"] == 3
    assert [i["hazard"] for i in body["items"]] == ["flood", "heavy_rain"]          # level_num 내림차순
    assert body["items"][0]["area_id"] == 7 and body["items"][0]["location"] == {"lat": 35.9907, "lng": 129.5561}
    assert body["data_stale"] is False


def test_point_risk_normal_and_stale(client, fake_db):
    body = client.get("/api/v1/risk", params={"lat": 35.9, "lng": 129.5}).json()
    assert body["max_level"] == "normal" and body["items"] == [] and body["data_stale"] is True
    assert client.get("/api/v1/risk", params={"lat": 35.9, "lng": 129.5, "radius_m": 9999}).status_code == 422


def test_risk_areas_api(client, fake_db):
    fake_db.rows["ST_AsGeoJSON(ra.area"] = [area_row(7, "flood", "warning", "침수 경보", "환승센터")]
    r = client.get("/api/v1/risk/areas", params={"hazard": "flood"})
    f = r.json()["features"][0]
    assert r.headers["content-type"].startswith("application/geo+json")
    assert f["id"] == 7 and f["properties"]["area_id"] == 7 and f["geometry"]["type"] == "MultiPolygon"
    assert client.get("/api/v1/risk/areas", params={"hazard": "flooding"}).status_code == 422
    assert client.get("/api/v1/dashboard/layers/risk_areas").json()["features"][0]["id"] == 7


def test_simulate_requires_internal_token(client, monkeypatch):
    from app.config import settings
    object.__setattr__(settings, "internal_token", "s3cret")
    try:
        assert client.post("/api/v1/internal/simulate", json={"scenario": "clear"}).status_code == 401
    finally:
        object.__setattr__(settings, "internal_token", None)
    assert client.post("/api/v1/internal/simulate", json={"scenario": "nope"}).status_code == 422
