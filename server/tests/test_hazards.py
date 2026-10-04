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
     "condition": {"all": [{"risk": "heavy_rain", "min_level": "advisory"},
                           {"within": "hazard_zones.landslide", "buffer_m": 100, "riskmap_area": "riskmap_g1_buf100"}]}},
    {"id": 11, "hazard": "landslide", "level": "warning", "label": "산사태 경고",
     "condition": {"all": [{"risk": "heavy_rain", "min_level": "warning"},
                           {"within": "hazard_zones.landslide", "buffer_m": 100, "riskmap_area": "riskmap_g12_buf100"}]}},
]
ZONE = {"id": 1, "name": "포항시 남구 연일읍 자명리 산42임", "meta": {"emd": "연일읍"}, "lng": 129.31, "lat": 36.01}
ZONE_WITH_REASON = {"id": 2, "name": "포항시 남구 구룡포읍 삼정리 산126-2임",
                    "meta": {"emd": "구룡포읍", "reason": "과거 월류 피해 이력이 있으며, 계류 내 붕괴지가 관찰됨"}, "lng": 129.55, "lat": 36.01}
RISK_G1 = {"id": 901, "external_id": "riskmap_g1_buf100", "name": "산사태 주의 범위", "meta": {"role": "trigger_area"},
           "lng": 129.55, "lat": 35.99}
RISK_G12 = {"id": 902, "external_id": "riskmap_g12_buf100", "name": "산사태 경고 범위", "meta": {"role": "trigger_area"},
            "lng": 129.55, "lat": 35.99}
TYPHOON_RULES = [
    {"id": 7, "hazard": "typhoon", "level": "advisory", "label": "태풍주의보/영향권"},
    {"id": 8, "hazard": "typhoon", "level": "warning", "label": "태풍경보"},
]


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


def test_landslide_warning_keeps_same_100m_buffer():
    """주의·경고 모두 100m — 흘러내리는 거리는 비의 세기가 아니라 지형으로 정해짐 (2026-10-02 개편)"""
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("warning", [ZONE], LANDSLIDE_RULES)
    assert (out[0].rule_id, out[0].buffer_m) == (11, 100)


def test_landslide_advisory_uses_grade1_riskmap_area_only():
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("advisory", [RISK_G1, RISK_G12], LANDSLIDE_RULES)
    assert len(out) == 1
    r = out[0]
    assert (r.rule_id, r.zone_id, r.key) == (10, 901, "landslide:riskmap")
    assert "1등급" in r.reason and "산림청" in r.reason and "발생 가능성" in r.reason


def test_landslide_warning_uses_grade12_riskmap_area():
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("warning", [RISK_G1, RISK_G12], LANDSLIDE_RULES)
    assert [(r.rule_id, r.zone_id) for r in out] == [(11, 902)]


def test_landslide_designated_zone_and_riskmap_together():
    """지정 취약지역은 위험지도 범위와 함께(합집합) 판정되고, 지정사유가 근거 문장에 들어감"""
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide("advisory", [RISK_G1, ZONE_WITH_REASON], LANDSLIDE_RULES)
    kinds = sorted(r.basis["kind"] for r in out)
    assert kinds == ["designated", "riskmap"]
    d = next(r for r in out if r.basis["kind"] == "designated")
    assert d.zone_id is None and d.buffer_m == 100 and "지정사유: 과거 월류 피해 이력" in d.reason


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


# ------------------------------------------------------------------ 태풍 (rules 7·8) — 특보 발효 or 반경 진입
def test_typhoon_nothing_active_gives_none():
    from risk.hazards import evaluate_typhoon
    assert evaluate_typhoon([], {}, TYPHOON_RULES) is None


def test_typhoon_preliminary_warning_counts_as_advisory():
    from risk.hazards import evaluate_typhoon
    warnings = [{"level": "watch", "region_name": "포항시", "headline": "포항시 태풍예비특보", "issued_at": None}]
    r = evaluate_typhoon(warnings, {}, TYPHOON_RULES)
    assert (r.level, r.rule_id) == ("advisory", 7)
    assert "예비특보" in r.reason


def test_typhoon_warning_level():
    from risk.hazards import evaluate_typhoon
    warnings = [{"level": "warning", "region_name": "포항시", "headline": "포항시 태풍경보", "issued_at": None}]
    r = evaluate_typhoon(warnings, {}, TYPHOON_RULES)
    assert (r.level, r.rule_id) == ("warning", 8)


def test_typhoon_inside_gale_radius_without_warning_still_advisory():
    """특보가 아직 안 나도, 강풍반경(15m/s) 안에 들어오면 주의 단계로 판단"""
    from risk.hazards import evaluate_typhoon
    impacts = {"2611": {"in_15ms_now": True, "in_25ms_now": False, "now_distance_km": 80}}
    r = evaluate_typhoon([], impacts, TYPHOON_RULES)
    assert r.level == "advisory" and "80km" in r.reason


def test_typhoon_inside_storm_radius_is_warning():
    from risk.hazards import evaluate_typhoon
    impacts = {"2611": {"in_15ms_now": True, "in_25ms_now": True, "now_distance_km": 30}}
    r = evaluate_typhoon([], impacts, TYPHOON_RULES)
    assert (r.level, r.rule_id) == ("warning", 8)


def test_aws_station_id_matches_collector():
    """판정이 찾는 구룡포 AWS 이름 = 수집기가 저장하는 이름 (2026-10-05: "816" vs "aws_816" 로 호우·강풍 판정이 늘 건너뛰어졌다)"""
    from collector.converters import kma_warn_aws
    from collector.jobs import AWS_STN
    from risk import hazards
    st = kma_warn_aws.aws_station(AWS_STN)
    assert (hazards.AWS_SOURCE, hazards.AWS_EXTERNAL_ID) == (st["source_code"], st["external_id"])
