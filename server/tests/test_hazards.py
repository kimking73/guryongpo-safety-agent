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
     "condition": {"all": [{"warning": "heavy_rain", "min_level": "advisory"},
                           {"within": "hazard_zones.landslide", "buffer_m": 100}]}},
    {"id": 11, "hazard": "landslide", "level": "warning", "label": "산사태 경고",
     "condition": {"all": [{"warning": "heavy_rain", "min_level": "warning"},
                           {"within": "hazard_zones.landslide", "buffer_m": 100}]}},
]
ZONE = {"id": 1, "name": "포항시 남구 연일읍 자명리 산42임", "meta": {"emd": "연일읍"}, "lng": 129.31, "lat": 36.01}
ZONE_WITH_REASON = {"id": 2, "name": "포항시 남구 구룡포읍 삼정리 산126-2임",
                    "meta": {"emd": "구룡포읍", "reason": "과거 월류 피해 이력이 있으며, 계류 내 붕괴지가 관찰됨"}, "lng": 129.55, "lat": 36.01}
ADVISORY = {"level": "advisory", "headline": "포항시 호우주의보", "issued_at": NOW}
WARNING = {"level": "warning", "headline": "포항시 호우경보", "issued_at": NOW}
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


# ------------------------------------------------------------------ 산사태 (rules 10·11) — 기상청 호우특보 x 취약지역 100m
def test_landslide_unknown_warning_gives_nothing():
    """특보 수집이 끊겨 판단 불가(None)면 아무것도 만들지 않음 — 호출 측이 seen 에 안 넣어 기존 판정 유지"""
    from risk.hazards import evaluate_landslide
    assert evaluate_landslide(None, [ZONE], LANDSLIDE_RULES) == []


def test_landslide_no_warning_gives_nothing():
    from risk.hazards import evaluate_landslide
    assert evaluate_landslide({"level": "normal"}, [ZONE], LANDSLIDE_RULES) == []


def test_landslide_preliminary_warning_gives_nothing():
    """예비특보(watch)는 발령된 특보가 아님"""
    from risk.hazards import evaluate_landslide
    assert evaluate_landslide({"level": "watch", "headline": "호우 예비특보"}, [ZONE], LANDSLIDE_RULES) == []


def test_landslide_advisory_warning_gives_rule10_100m_circle():
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide(ADVISORY, [ZONE], LANDSLIDE_RULES)
    assert len(out) == 1
    r = out[0]
    assert (r.rule_id, r.level, r.buffer_m, r.zone_id) == (10, "advisory", 100, None)   # 지점 좌표 반경 100m 원
    assert (r.lng, r.lat) == (ZONE["lng"], ZONE["lat"])
    assert r.basis["trigger"] == "kma_warning" and r.basis["warning_level"] == "advisory"
    assert "기상청 포항시 호우주의보 발효 중" in r.reason and "100m 이내" in r.reason


def test_landslide_warning_gives_rule11_same_100m():
    """주의·경고 모두 100m — 흘러내리는 거리는 비의 세기가 아니라 지형으로 정해짐"""
    from risk.hazards import evaluate_landslide
    out = evaluate_landslide(WARNING, [ZONE, ZONE_WITH_REASON], LANDSLIDE_RULES)
    assert [(r.rule_id, r.buffer_m) for r in out] == [(11, 100), (11, 100)]
    assert "지정사유: 과거 월류 피해 이력" in out[1].reason


def test_landslide_headline_fallback():
    from risk.hazards import evaluate_landslide
    r = evaluate_landslide({"level": "warning"}, [ZONE], LANDSLIDE_RULES)[0]
    assert "기상청 포항시 호우경보 발효 중" in r.reason


def test_landslide_zones_sql_uses_designated_zones_only():
    """산림청 산사태위험지도(riskmap_*) 는 판정에 쓰지 않음 — 공공데이터포털 지정 취약지역만"""
    from risk.hazards import ZONES_SQL
    assert "source_code = 'datagokr'" in ZONES_SQL and "riskmap" not in ZONES_SQL


def test_landslide_reason_avoids_certainty_language():
    """토양수분 실측/예측이 아니므로 '발생'을 단정하지 않고 가능성·대비로만 표현한다"""
    from risk.hazards import evaluate_landslide
    r = evaluate_landslide(ADVISORY, [ZONE], LANDSLIDE_RULES)[0]
    assert "발생 가능성" in r.reason
    assert "산사태가 발생" not in r.reason and "산사태 발생했" not in r.reason


def test_current_warning_stale_collection_is_unknown(monkeypatch):
    """특보 수집이 40분 넘게 성공하지 못했으면 '특보 없음'이 아니라 판단 불가(None)"""
    from risk import hazards
    monkeypatch.setattr(hazards.db, "fetch_one",
                        lambda sql, params=None: {"at": NOW - timedelta(minutes=41)} if "ingest_runs" in sql else None)
    assert hazards.current_heavy_rain_warning(NOW) is None


def test_current_warning_fresh_collection(monkeypatch):
    from risk import hazards

    def fetch_one(sql, params=None):
        if "ingest_runs" in sql:
            return {"at": NOW - timedelta(minutes=5)}
        assert params == {"region": "L1072400"}
        return {"level": "warning", "headline": "포항시 호우경보", "issued_at": NOW}
    monkeypatch.setattr(hazards.db, "fetch_one", fetch_one)
    assert hazards.current_heavy_rain_warning(NOW)["level"] == "warning"


def test_current_warning_none_active(monkeypatch):
    from risk import hazards
    monkeypatch.setattr(hazards.db, "fetch_one",
                        lambda sql, params=None: {"at": NOW - timedelta(minutes=5)} if "ingest_runs" in sql else None)
    assert hazards.current_heavy_rain_warning(NOW) == {"level": "normal"}


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


def test_sync_matches_existing_rows_by_engine_and_closes_duplicates(monkeypatch):
    """hazards 판정은 engine='hazards_v1' 로 기존 영역을 찾아야 해제(특보 해제·정상 복귀)가 반영된다.
    같은 대상이 여러 행이면(예전 중복) 최신 1개만 남긴다"""
    from contextlib import contextmanager
    from risk import engine
    calls = []

    class Conn:
        def execute(self, sql, params=None):
            calls.append((sql, params))
            rows = [{"id": 1, "key": "landslide:zone:7", "level": "warning", "rule_id": 11, "station_id": -107, "expired": False},
                    {"id": 2, "key": "landslide:zone:7", "level": "warning", "rule_id": 11, "station_id": -107, "expired": False}]
            return type("R", (), {"fetchall": lambda self: rows if sql is engine.ACTIVE_SQL else []})()

    @contextmanager
    def connection():
        yield Conn()
    monkeypatch.setattr(engine.db, "connection", connection)
    stats = engine.sync([], {-107}, engine="hazards_v1")
    assert calls[0][1]["engine"] == "hazards_v1"
    assert stats["closed"] == 2 and sorted(calls[-1][1]["ids"]) == [1, 2]
