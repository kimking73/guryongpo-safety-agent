"""DB 조회 tool (B3): 가짜 조회 함수로 결과 변환·장애 대체를 확인한다 (DB 없이 실행)."""

from datetime import datetime, timedelta, timezone

import pytest

from guardian_ai import tools as T
from guardian_ai.state import ActionGuide, RiskLevel

KST = timezone(timedelta(hours=9))
NOW = datetime.now(KST)


class FakeDB:
    """SQL에 들어 있는 테이블 이름으로 돌려줄 행을 고른다. 받은 파라미터를 기록한다."""

    def __init__(self, rows_by_table: dict[str, list[dict]]):
        self.rows_by_table, self.calls = rows_by_table, []

    def __call__(self, sql, params):
        self.calls.append((sql, params))
        for table, rows in self.rows_by_table.items():
            if table in sql:
                return rows
        return []


def broken(sql, params):
    raise TimeoutError("DB 응답 없음")


def test_every_db_tool_degrades_instead_of_raising():
    calls = [
        lambda: T.get_risk_at(35.99, 129.55, fetch=broken),
        lambda: T.get_observations("water_level", 35.99, 129.55, fetch=broken),
        lambda: T.get_weather_warnings(fetch=broken),
        lambda: T.get_disaster_messages(fetch=broken),
        lambda: T.get_hazard_zones(35.99, 129.55, fetch=broken),
        lambda: T.get_facilities("shelter", 35.99, 129.55, fetch=broken),
        lambda: T.get_life_safety(35.99, 129.55, fetch=broken),
        lambda: T.get_action_guides("flood", "during", fetch=broken),
    ]
    for call in calls:
        out = call()
        assert out["available"] is False and "확인할 수 없습니다" in out["reason"] and out["source"]


def test_risk_sorts_by_level_and_carries_engine_reason():
    db = FakeDB({
        "risk_assessments": [
            {"id": 1, "hazard": "heavy_rain", "level": "advisory", "label": "호우 주의", "rule_id": 26,
             "basis": {"reason": "강우량계 주의 등급"}, "computed_at": NOW, "distance_m": 0.0},
            {"id": 2, "hazard": "flood", "level": "warning", "label": "침수 경계", "rule_id": 9,
             "basis": '{"reason": "구룡포수협 지표면 수위계 침수심 160mm (기준 150mm)", "metric": "flood_depth",'
                      ' "value": 160, "unit": "mm", "simulated": true}',
             "computed_at": NOW, "distance_m": 140.4},
        ],
        "ingest_runs": [{"t": NOW - timedelta(minutes=5)}],
    })
    out = T.get_risk_at(35.99, 129.55, radius_m=300, fetch=db)
    assert out["max_level"] == "warning" and not out["data_stale"]
    top = out["items"][0]
    assert top["hazard"] == "flood" and top["value"] == 160 and top["distance_m"] == 140
    assert "기준 150mm" in top["reason"] and top["simulated"] is True
    assert db.calls[0][1] == {"lat": 35.99, "lon": 129.55, "radius_m": 300}


def test_risk_without_recent_engine_run_is_stale():
    out = T.get_risk_at(35.99, 129.55, fetch=FakeDB({"ingest_runs": [{"t": NOW - timedelta(hours=2)}]}))
    assert out["max_level"] == "normal" and out["data_stale"] is True


def test_observations_mark_level_and_staleness():
    db = FakeDB({"v_latest_observations": [
        {"station_id": 9, "station_name": "구룡포환승센터_지표면 수위계", "station_kind": "road_flood",
         "metric": "flood_depth", "value": 160.0, "unit": "mm", "source_level": 4,
         "observed_at": NOW - timedelta(minutes=10), "distance_m": 22.2},
        {"station_id": 1, "station_name": "구룡포교_하천수위계", "station_kind": "river_level",
         "metric": "river_level", "value": 0.0, "unit": "mm", "source_level": None,
         "observed_at": NOW - timedelta(hours=5), "distance_m": 900.0},
    ]})
    out = T.get_observations("water_level", 35.99, 129.55, fetch=db)
    first, second = out["items"]
    assert first["level_label"] == "경보" and first["stale"] is False and first["distance_m"] == 22
    assert second["level_label"] is None and second["stale"] is True
    assert db.calls[0][1]["metrics"] == ["flood_depth", "river_level", "manhole_level"]


def test_warning_status():
    db = FakeDB({"weather_warnings": [
        {"hazard": "heavy_rain", "level": "warning", "region_name": "포항시", "issued_at": NOW,
         "effective_at": NOW, "released_at": None, "headline": "호우경보"},
        {"hazard": "strong_wind", "level": "watch", "region_name": "포항시", "issued_at": NOW,
         "effective_at": None, "released_at": None, "headline": "강풍 예비특보"},
        {"hazard": "typhoon", "level": "advisory", "region_name": "포항시", "issued_at": NOW,
         "effective_at": NOW, "released_at": NOW, "headline": "태풍주의보 해제"},
    ]})
    assert [w["status"] for w in T.get_weather_warnings(fetch=db)["items"]] == ["active", "planned", "lifted"]


def test_uv_and_dust_grades():
    db = FakeDB({"v_latest_observations": [
        {"station_id": 21, "station_name": "구룡포 자외선지수 (전역)", "station_kind": "uv", "metric": "uv_index",
         "value": 5.2, "unit": "index", "source_level": None, "observed_at": NOW, "distance_m": 10.0},
    ]})
    out = T.get_life_safety(35.99, 129.55, fetch=db)
    assert out["uv"]["grade"] == "보통"           # 5.2 → 기상청 3–5 보통 (6부터 높음)
    assert T._grade(31, T.PM10_GRADES) == "보통" and T._grade(76, T.PM25_GRADES) == "매우나쁨"


def test_action_guides_always_include_all_and_match_state_model():
    row = {"id": 1, "disaster": "heavy_rain", "phase": "during", "min_level": "advisory", "targets": ["all"],
           "priority": 10, "title": "호우가 시작되면", "content": "신속히 안전한 곳으로 대피하고 외출을 삼갑니다.",
           "voice_text": None, "source_name": "포항시 재난안전 홈페이지", "source_url": None}
    db = FakeDB({"action_guides": [row]})
    out = T.get_action_guides("heavy_rain", "during", "warning", ["fisher"], fetch=db)
    assert db.calls[0][1]["targets"] == ["all", "fisher"]
    guide = ActionGuide(**out["items"][0])        # 행 키 = 상태 모델 키
    assert guide.min_level == RiskLevel.ADVISORY


def test_facility_shape():
    db = FakeDB({"shelters": [
        {"id": 7, "name": "구룡포초등학교", "shelter_types": ["tsunami"], "address": "구룡포읍", "capacity": 300,
         "phone": None, "is_indoor": True, "is_accessible": None, "lat": 35.98912345, "lon": 129.5512, "distance_m": 333.6},
    ]})
    item = T.get_facilities("shelter", 35.99, 129.55, fetch=db)["items"][0]
    assert item["facility_id"] == 7 and item["distance_m"] == 334 and item["lat"] == 35.989123
    assert "id" not in item


def test_risk_level_order_matches_db():
    assert [lv.value for lv in RiskLevel] == T.LEVEL_ORDER
    assert RiskLevel.CRITICAL.rank > RiskLevel.WARNING.rank > RiskLevel.NORMAL.rank


@pytest.mark.parametrize("kind", list(T.OBSERVATION_METRICS))
def test_observation_kinds_are_defined(kind):
    kinds, metrics = T.OBSERVATION_METRICS[kind]
    assert kinds and metrics
