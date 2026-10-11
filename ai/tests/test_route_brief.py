"""AI 경로 설명 /api/ai/route-brief (DB·LLM 없이): 근거 구성, 숫자 틀린 문장 → 템플릿, tool 실패, 캐시."""

from fastapi.testclient import TestClient

from guardian_ai import route_brief as RB
from guardian_ai.api import app, get_route_brief

ROUTE = {"distance_m": 1001, "duration_s": 721, "ascend_m": 40, "max_uphill_pct": 31, "steps_m": 24, "steep_up_m": 136,
         "very_steep_up_m": 85, "avoided": ["z1"], "still_inside": ["z2"], "strategy": "safest", "geometry": "abc"}
BODY = {"origin": {"lat": 35.9905, "lon": 129.556, "name": "현위치"},
        "destination": {"lat": 35.9868, "lon": 129.548, "name": "구룡포 실내체육관"},
        "route": ROUTE, "zone_names": {"z1": "침수 위험 영역 A", "z2": "산사태 위험 영역 B"}}


def fetch(sql, params):
    """가짜 DB: 출발지는 침수 경보 영역 안, 특보 1건, 비 12mm·순간풍속 16m/s."""
    if "labels" in sql:
        return [{"labels": "침수 경보" if abs(params["lat"] - 35.9905) < 1e-6 else None}]
    if "weather_warnings" in sql:
        return [{"hazard": "heavy_rain", "level": "warning", "region_name": "포항", "headline": "포항시 호우경보",
                 "released_at": None, "issued_at": None, "effective_at": None}]
    metrics = params.get("metrics") or []
    row = {"station_name": "구룡포 AWS", "station_kind": "weather", "unit": None, "source_level": None,
           "observed_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc), "distance_m": 300}
    if "rain_1h" in metrics:
        return [{**row, "metric": "rain_1h", "value": 12.0}]
    if "wind_gust" in metrics:
        return [{**row, "metric": "wind_gust", "value": 16.0}, {**row, "metric": "wind_speed", "value": 9.0}]
    return []


def req(**over):
    return RB.RouteBriefRequest.model_validate({**BODY, **over})


def test_evidence_and_template_come_from_route_and_db():
    ev, missing = RB.build_evidence(req(), fetch)
    keys = {e.key: e for e in ev}
    assert missing == []
    assert keys["경로 거리"].value == 1001 and keys["소요 시간"].value == 13 and keys["계단 길이"].value == 24
    assert keys["다른 길이 없어 지나는 위험 구역 1곳"].value == "산사태 위험 영역 B"      # id → 앱이 보낸 이름
    assert keys["출발지 위험"].value == "지금 위험 영역 안(침수 경보)" and "도착지 위험" not in keys
    many, _ = RB.build_evidence(req(route={**ROUTE, "still_inside": ["침수 경보", "침수 경보", "산사태 경고"]}, zone_names={}), fetch)
    assert {e.key: e.value for e in many}["다른 길이 없어 지나는 위험 구역 3곳"] == "침수 경보 2곳, 산사태 경고"   # 같은 이름은 묶는다
    assert keys["발효 중인 특보"].value == "포항시 호우경보"
    assert keys["1시간 강수량 (관측소: 구룡포 AWS)"].value == 12.0 and "경로 위 위험 구역" not in keys
    short, _ = RB.build_evidence(req(route={**ROUTE, "steep_up_m": 3, "very_steep_up_m": 3, "steps_m": 5}), fetch)
    assert not any("오르막 길이" in e.key or "계단" in e.key for e in short)                  # 몇 m짜리는 말하지 않는다

    out = RB.template_brief(req(), ev, missing)
    assert out.used_template and "1001m" in out.summary and "13분" in out.summary and "침수 위험 영역 A" in out.summary
    assert out.hazards[0].startswith("다른 길이 없어 위험 구역을 지납니다: 산사태 위험 영역 B")   # 지나는 구역이 맨 앞
    assert any("136m" in c and "85m" in c and "31%" in c for c in out.cautions) and any("계단이 24m" in c for c in out.cautions)
    assert any("12mm" in c for c in out.cautions) and any("16m/s" in c for c in out.cautions)


def test_writer_is_used_only_when_numbers_match_evidence():
    good = RB.RouteBriefService(writer=lambda ev, t: ("구룡포 실내체육관까지 1001m, 약 13분입니다.", ["계단이 24m 있습니다."], []),
                                fetch=fetch).brief(req())
    assert not good.used_template and good.cautions == ["계단이 24m 있습니다."] and good.timings["total"] >= 0

    bad = RB.RouteBriefService(writer=lambda ev, t: ("도착지까지 800m입니다.", [], []), fetch=fetch).brief(req())
    assert bad.used_template and "1001m" in bad.summary and "800m" not in bad.summary

    none_avoided = req(route={**ROUTE, "avoided": []})
    lie = RB.RouteBriefService(writer=lambda ev, t: ("구룡포 실내체육관까지 1001m입니다. 위험 구역을 피해 갑니다.", [], []),
                               fetch=fetch).brief(none_avoided)
    assert lie.used_template and "피해" not in lie.summary              # 피한 구역이 없는데 피했다고 쓰면 버린다

    def broken(ev, t):
        raise TimeoutError("openai")
    assert RB.RouteBriefService(writer=broken, fetch=fetch).brief(req()).used_template


def test_failed_lookups_are_named_and_safe_route_says_no_zone():
    def down(sql, params):
        raise RuntimeError("db down")
    ev, missing = RB.build_evidence(req(route={**ROUTE, "still_inside": [], "avoided": []}), down)
    assert {"출발지 위험 여부", "도착지 위험 여부", "기상특보", "비 관측값", "바람 관측값"} <= set(missing)
    assert any(e.key == "경로 위 위험 구역" and e.value == "없음" for e in ev)
    out = RB.template_brief(req(), ev, missing)
    assert any("확인하지 못한 정보" in c for c in out.cautions)

    car, _ = RB.build_evidence(req(route={**ROUTE, "mode": "car"}), fetch)
    assert not any("오르막" in e.key or "계단" in e.key for e in car)


def test_api_roundtrip_and_cache():
    calls = []

    def writer(ev, t):
        calls.append(ev)
        return t.summary, t.cautions[:3], t.hazards[:3]
    service = RB.RouteBriefService(writer=writer, fetch=fetch)
    app.dependency_overrides[get_route_brief] = lambda: service
    c = TestClient(app)
    first = c.post("/api/ai/route-brief", json=BODY)
    assert first.status_code == 200 and first.json()["summary"] and first.json()["note"]
    second = c.post("/api/ai/route-brief", json=BODY)
    assert len(calls) == 1 and second.json()["timings"].get("cached") == 1.0          # 같은 요청은 다시 쓰지 않는다
    c.post("/api/ai/route-brief", json={**BODY, "route": {**ROUTE, "distance_m": 900}})
    assert len(calls) == 2
    assert c.post("/api/ai/route-brief", json={"origin": BODY["origin"]}).status_code == 422


SEA = {"port_name": "구룡포항", "distance_m": 820, "bearing_label": "북서쪽", "direct": False}


def test_sea_route_brief_covers_sea_leg_and_land_leg():
    """해상 경로: 바닷길(항구·거리·방향·모양) + 항구 → 대피소 육상 구간. 안내 글도 해상용."""
    r = req(sea=SEA, route={**ROUTE, "avoided": [], "still_inside": []})
    ev, missing = RB.build_evidence(r, fetch)
    keys = {e.key: e.value for e in ev}
    assert keys["들어갈 항구"] == "구룡포항" and keys["바닷길 거리 (항구까지)"] == 820 and keys["항구 방향"] == "북서쪽"
    assert keys["항구에서 도착지까지 경로 거리"] == 1001 and "바닷길 모양" in keys and missing == []
    out = RB.template_brief(r, ev, missing)
    assert "북서쪽 구룡포항까지 바닷길 820m" in out.summary and "1001m" in out.summary and out.note == RB.SEA_NOTE
    assert any("방파제" in c for c in out.cautions)
    # '방파제를 피해'는 정상 표현 — 위험 구역을 피했다는 말이 아니므로 LLM 문장을 버리지 않는다
    ok = RB.RouteBriefService(writer=lambda e, t: ("구룡포항까지 바닷길 820m입니다.", ["방파제를 피해 돌아 들어가세요."], []),
                              fetch=fetch).brief(r)
    assert not ok.used_template and ok.note == RB.SEA_NOTE
    bad = RB.RouteBriefService(writer=lambda e, t: ("구룡포항까지 바닷길 820m입니다. 위험 구역을 피해 갑니다.", [], []),
                               fetch=fetch).brief(r)
    assert bad.used_template


def test_sea_route_without_land_leg_or_path_says_what_is_missing():
    r = req(sea={**SEA, "path_found": False}, route=None)
    ev, missing = RB.build_evidence(r, fetch)
    assert any("바닷길" in m for m in missing) and any("육상 경로" in m for m in missing)
    out = RB.template_brief(r, ev, missing)
    assert "구룡포항까지 바닷길 820m" in out.summary and any("확인하지 못한 정보" in c for c in out.cautions)


def test_visit_route_brief_counts_stops_and_passing_zones():
    """방재단 방문 경로: 몇 곳·전체 거리, 서버가 풀어 준 구역(blocked_zones)도 지나는 구역으로. 도착지는 따로 없다."""
    r = req(visits={"stops": 4, "by_priority": True, "blocked_zones": ["z3"]},
            route={**ROUTE, "avoided": [], "still_inside": ["z2"], "strategy": None},
            zone_names={"z2": "산사태 경고", "z3": "침수 경보"})
    ev, missing = RB.build_evidence(r, fetch)
    keys = {e.key: e.value for e in ev}
    assert keys["방문할 곳"] == "4곳" and keys["전체 거리"] == 1001 and "도착지" not in keys and "경로 방식" not in keys
    assert keys["다른 길이 없어 지나는 위험 구역 2곳"] == "산사태 경고, 침수 경보"
    out = RB.template_brief(r, ev, missing)
    assert out.summary.startswith("4곳을 모두 도는 길은 1001m") and out.note == RB.VISIT_NOTE


def test_request_needs_a_land_route_or_a_sea_leg():
    import pytest
    with pytest.raises(ValueError):
        req(route=None)
