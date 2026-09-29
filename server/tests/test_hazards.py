"""호우·강풍·산사태 판정 (A4) — risk_rules 1~4, 10~11 을 코드 없이 순수 함수로 검증"""
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
NOW = datetime(2026, 10, 5, 14, 27, tzinfo=KST)

# seed.sql 의 risk_rules 1~4, 10~11 과 같은 조건 (JSON 만 발췌)
RAIN_RULES = [
    {"id": 1, "hazard": "heavy_rain", "level": "advisory", "label": "호우주의보",
     "condition": {"any": [{"metric": "rain_3h", "op": ">=", "value": 60}, {"metric": "rain_12h", "op": ">=", "value": 110}]}},
    {"id": 2, "hazard": "heavy_rain", "level": "warning", "label": "호우경보",
     "condition": {"any": [{"metric": "rain_3h", "op": ">=", "value": 90}, {"metric": "rain_12h", "op": ">=", "value": 180}]}},
]
WIND_RULES = [
    {"id": 3, "hazard": "strong_wind", "level": "advisory", "label": "강풍주의보", "condition": {
        "land": {"any": [{"metric": "wind_speed", "op": ">=", "value": 14}, {"metric": "wind_gust", "op": ">=", "value": 20}]},
        "mountain": {"any": [{"metric": "wind_speed", "op": ">=", "value": 17}, {"metric": "wind_gust", "op": ">=", "value": 25}]}}},
    {"id": 4, "hazard": "strong_wind", "level": "warning", "label": "강풍경보", "condition": {
        "land": {"any": [{"metric": "wind_speed", "op": ">=", "value": 21}, {"metric": "wind_gust", "op": ">=", "value": 26}]},
        "mountain": {"any": [{"metric": "wind_speed", "op": ">=", "value": 24}, {"metric": "wind_gust", "op": ">=", "value": 30}]}}},
]
LANDSLIDE_RULES = [
    {"id": 10, "hazard": "landslide", "level": "advisory", "label": "산사태 주의",
     "condition": {"all": [{"risk": "heavy_rain", "min_level": "advisory"}, {"within": "hazard_zones.landslide", "buffer_m": 100}]}},
    {"id": 11, "hazard": "landslide", "level": "warning", "label": "산사태 경고",
     "condition": {"all": [{"risk": "heavy_rain", "min_level": "warning"}, {"within": "hazard_zones.landslide", "buffer_m": 0}]}},
]
ZONE = {"id": 1, "name": "포항시 남구 연일읍 자명리 산42임", "meta": {"emd": "연일읍"}, "lng": 129.31, "lat": 36.01}


# ------------------------------------------------------------------ 호우 (rules 1·2)
def test_heavy_rain_no_data():
    from risk.hazards import evaluate_heavy_rain
    assert evaluate_heavy_rain(None, None, NOW, RAIN_RULES) is None


def test_heavy_rain_below_threshold():
    from risk.hazards import evaluate_heavy_rain
    assert evaluate_heavy_rain(30, 80, NOW, RAIN_RULES) is None


def test_heavy_rain_3h_triggers_warning():
    from risk.hazards import evaluate_heavy_rain
    r = evaluate_heavy_rain(95, 80, NOW, RAIN_RULES)
    assert (r.level, r.rule_id) == ("warning", 2)


def test_heavy_rain_advisory_cites_matched_metric():
    from risk.hazards import evaluate_heavy_rain
    r = evaluate_heavy_rain(65, 80, NOW, RAIN_RULES)
    assert (r.level, r.rule_id) == ("advisory", 1)
    assert "3시간" in r.reason and "60mm" in r.reason


def test_heavy_rain_12h_alone_can_trigger_warning():
    from risk.hazards import evaluate_heavy_rain
    r = evaluate_heavy_rain(30, 190, NOW, RAIN_RULES)
    assert (r.level, r.rule_id) == ("warning", 2)


# ------------------------------------------------------------------ 강풍 (rules 3·4, 육상/산지 분기)
def test_strong_wind_land_advisory():
    from risk.hazards import evaluate_strong_wind
    r = evaluate_strong_wind(15, None, False, NOW, WIND_RULES)
    assert r.level == "advisory"


def test_strong_wind_mountain_needs_higher_speed():
    from risk.hazards import evaluate_strong_wind
    assert evaluate_strong_wind(15, None, True, NOW, WIND_RULES) is None
    assert evaluate_strong_wind(18, None, True, NOW, WIND_RULES).level == "advisory"


def test_strong_wind_gust_triggers_warning():
    from risk.hazards import evaluate_strong_wind
    r = evaluate_strong_wind(None, 27, False, NOW, WIND_RULES)
    assert (r.level, r.rule_id) == ("warning", 4)


# ------------------------------------------------------------------ 산사태 (rules 10·11) — 위치 x 호우 단계
def test_landslide_unknown_heavy_rain_gives_nothing():
    from risk.hazards import evaluate_landslide
    assert evaluate_landslide(None, [ZONE], LANDSLIDE_RULES) == []


def test_landslide_below_advisory_gives_nothing():
    from risk.hazards import evaluate_landslide
    assert evaluate_landslide("watch", [ZONE], LANDSLIDE_RULES) == []


def test_landslide_advisory_uses_wider_buffer():
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("advisory", [ZONE], LANDSLIDE_RULES)
    assert len(out) == 1 and (out[0].rule_id, out[0].buffer_m) == (10, 100)


def test_landslide_warning_uses_zone_itself():
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("warning", [ZONE], LANDSLIDE_RULES)
    assert (out[0].rule_id, out[0].buffer_m) == (11, 0)


def test_landslide_critical_still_uses_warning_rule():
    """호우가 심각(critical) 이어도 산사태는 경고(11번)까지만 — 더 높은 산사태 단계는 없음"""
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("critical", [ZONE], LANDSLIDE_RULES)
    assert out[0].rule_id == 11


def test_landslide_reason_avoids_certainty_language():
    """토양수분 실측/예측이 아니므로 '발생'을 단정하지 않고 가능성·대비로만 표현한다"""
    from risk.hazards import evaluate_landslide
    r = evaluate_landslide("advisory", [ZONE], LANDSLIDE_RULES)[0]
    assert "발생 가능성" in r.reason
    assert "산사태가 발생" not in r.reason and "산사태 발생했" not in r.reason
