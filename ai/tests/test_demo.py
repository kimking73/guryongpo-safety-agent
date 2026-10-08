"""앱 시연 모드(ChatRequest.demo, demo.py)와 해상 경로(B11 request_sea_route) — DB·api·경로 서버 없이 실행."""

import json

import httpx

from guardian_ai import demo as D
from guardian_ai import graph as G
from guardian_ai import location as L
from guardian_ai import tools as T
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import Location, Specialist, SpecialistResult, UserProfile

from tests.test_location import LAND_ROUTE, flood_db, route_server

AREA = {"type": "Feature", "id": -3,
        "geometry": {"type": "MultiPolygon", "coordinates": [[[[129.55, 35.99], [129.56, 35.99], [129.56, 36.0], [129.55, 36.0], [129.55, 35.99]]]]},
        "properties": {"hazard": "flood", "level": "warning", "label": "침수 경보", "reason": "구룡포수협 4단계 (모의)",
                       "rule_id": 23, "area_id": -3, "simulated": True},
        "basis": {"metric": "manhole_level", "value": 0, "simulated": True, "demo": True}}
STATIONS = [
    {"id": 22, "properties": {"kind": "weather", "metric": "wind_speed", "unit": "m/s", "simulated": True,
                              "observed_at": "2026-10-07T13:08:00+09:00", "metrics": {"rain_1h": 41.5, "wind_speed": 16.5, "temp": 19.2}}},
    {"id": 23, "properties": {"kind": "weather", "metric": "temp", "simulated": False,       # 초단기실황: 시나리오와 겹쳐 뺀다
                              "observed_at": "2026-10-07T12:00:00+09:00", "metrics": {"rain_1h": 0.0}}},
    {"id": 21, "properties": {"kind": "uv", "metric": "uv_index", "unit": "index", "simulated": False,   # 자외선은 실측 그대로
                              "observed_at": "2026-10-07T12:53:00+09:00", "metrics": {"uv_index": 7.4}}},
]
DASHBOARD = {"widgets": [
    {"type": "warnings", "data": {"items": [{"label": "[시연] 포항시 호우경보", "hazard": "heavy_rain", "level": "warning",
                                             "region_name": "포항시", "issued_at": "2026-10-07T11:39:00+09:00"}]}},
    {"type": "disaster_messages", "data": {"items": [{"sent_at": "2026-10-07T11:59:00+09:00", "sender": "포항시",
                                                      "alert_class": "긴급재난", "message": "[시연] 호우경보 발효"}]}},
    {"type": "forecast", "data": {"slots": [{"t": "2026-10-07T14:09:00+09:00", "pop": 95, "pty": "비", "pcp_mm": 35.0, "wsd": 17.5}]}},
    {"type": "wave", "data": {"series": [{"t": "2026-10-07T16:09:00+09:00", "v": 3.6}]}},
]}


def api(seen=None, status=200):
    def handler(req):
        if seen is not None:
            seen.append(req.url.path)
        if status != 200:
            return httpx.Response(status)
        body = {"/api/v1/demo/risk/areas": {"features": [AREA]}, "/api/v1/demo/layers/stations": {"features": STATIONS},
                "/api/v1/demo/dashboard": DASHBOARD}[req.url.path]
        return httpx.Response(200, json=body)
    return D.DemoSource(client=httpx.Client(base_url="http://api", transport=httpx.MockTransport(handler)))


def use_source(monkeypatch, source):
    monkeypatch.setattr(D, "_source", source)


# --- 시연 데이터 → 표 행 ---

def test_rows_follow_demo_endpoints():
    rows = api().rows()
    assert rows["areas"][0] | {"geometry": None} == {
        "id": -3, "hazard": "flood", "level": "warning", "label": "침수 경보", "rule_id": 23, "geometry": None,
        "basis": {"metric": "manhole_level", "value": 0, "simulated": True, "demo": True, "reason": "구룡포수협 4단계 (모의)"}}
    obs = {(r["station_id"], r["metric"]): r for r in rows["observations"]}
    assert set(obs) == {(22, "rain_1h"), (22, "wind_speed"), (21, "uv_index")}   # temp는 쓰지 않는 지표, 23은 시나리오와 겹침
    assert obs[(22, "rain_1h")]["unit"] == "mm" and obs[(22, "rain_1h")]["quality"] == "simulated"
    assert obs[(21, "uv_index")]["quality"] is None
    assert rows["warnings"][0]["headline"] == "포항시 호우경보" and rows["warnings"][0]["released_at"] is None
    assert rows["messages"][0]["message"] == "호우경보 발효"
    cats = {(r["grid_nx"], r["category"]) for r in rows["forecasts"]}
    assert cats == {(nx, c) for nx in (105, 106) for c in ("POP", "PTY", "PCP", "WSD", "WAV")}


def test_rows_are_cached():
    seen = []
    src = api(seen)
    src.rows(), src.rows()
    assert len(seen) == 3


def test_rewrite_shadows_only_live_tables():
    rows = api().rows()
    sql, params = D.rewrite(T.SAFE_SHELTERS_SQL, {"lat": 1}, rows)
    assert sql.startswith("WITH risk_assessments AS (") and sql.endswith(T.SAFE_SHELTERS_SQL)
    assert json.loads(params["_demo_areas"])[0]["label"] == "침수 경보" and params["lat"] == 1
    obs_sql, obs_params = D.rewrite(T.OBS_SQL, {}, rows)
    assert "observations AS (" in obs_sql and "_demo_observations" in obs_params
    assert D.rewrite(T.SHELTERS_SQL, {"a": 1}, rows) == (T.SHELTERS_SQL, {"a": 1})   # 고정 자료는 그대로
    run_sql, _ = D.rewrite(T.RISK_SQL + ";" + T.RISK_LAST_RUN_SQL, {}, rows)
    assert "ingest_runs AS (" in run_sql


# --- tool에 연결 ---

def test_tools_read_demo_tables_only_in_demo_mode(monkeypatch):
    use_source(monkeypatch, api())
    sent = []

    def fetch(sql, params):
        sent.append((sql, params))
        return []

    T.get_risk_at(35.99, 129.55, fetch=fetch)
    assert all(not s.startswith("WITH") for s, _ in sent)
    sent.clear()
    with D.active(True):
        T.get_risk_at(35.99, 129.55, fetch=fetch)
    assert sent and all(s.startswith("WITH") and "_demo_areas" in p for s, p in sent if "risk_assessments" in s)
    assert not D.is_active()


def test_demo_api_down_means_unavailable_not_real_data(monkeypatch):
    use_source(monkeypatch, api(status=500))
    called = []
    with D.active(True):
        res = T.get_weather_warnings(fetch=lambda sql, params: called.append(sql) or [])
    assert res["available"] is False and "DemoUnavailable" in res["reason"] and called == []


def test_route_tools_send_demo_flag():
    sent = []
    T.request_route((35.99, 129.55), (35.98, 129.54), client=route_server(sent))
    with D.active(True):
        T.request_route((35.99, 129.55), (35.98, 129.54), client=route_server(sent))
        T.request_sea_route((35.99, 129.58), client=route_server(sent))
    assert "demo" not in sent[0] and sent[1]["demo"] is True and sent[2]["demo"] is True
    assert "destination" not in sent[2]


def test_chat_turns_demo_on_for_nodes_and_still_updates_profile(monkeypatch):
    seen, extracted = [], []

    def node(state):
        seen.append(D.is_active())
        return {"specialist_results": [SpecialistResult(agent=Specialist.RAIN_FLOOD, summary="침수 경보입니다.")]}

    svc = ChatService(classifier=G.keyword_classify, overrides={Specialist.RAIN_FLOOD.value: node},
                      extractor=lambda *a, **k: extracted.append(a))
    svc.writer = object()               # 실제로 부르지 않음 (추출 결과가 None 이라 반영 전에 끝남)
    svc.chat(ChatRequest(user_id="u1", question="침수 위험 있어?", demo=True), verified_uid="u1", token="t")
    svc.chat(ChatRequest(user_id="u1", question="침수 위험 있어?"), verified_uid="u1", token="t")
    assert seen == [True, False]
    assert len(extracted) == 2          # 시연 대화에서 들은 사용자 정보도 프로필에 반영 (2026-10-08)
    assert not D.is_active()


# --- 해상 경로 (B11) ---

SEA = {"at_sea": True,
       "port": {"id": "port-1", "name": "구룡포항", "kind": "항", "berth": {"lat": 35.9912, "lon": 129.5585},
                "land_point": {"lat": 35.9915, "lon": 129.5575}},
       "sea_leg": {"distance_m": 1830, "straight_m": 1620, "bearing_deg": 250.0, "bearing_label": "서남서쪽", "direct": False,
                   "path": "xyz", "path_found": True, "alternatives": [{"id": "port-2", "name": "삼정항", "distance_m": 2400,
                                                                       "bearing_deg": 200.0, "bearing_label": "남남서쪽"}]},
       "destination": {"name": None, "lat": 35.99, "lon": 129.55}, "land_route": LAND_ROUTE}
AT_SEA = Location(lat=35.995, lon=129.575, label="현재 위치")


def sea_state():
    return {"mode": "chat", "question": "어디로 대피해야 해?", "current_location": AT_SEA,
            "user": UserProfile(user_id="u1", age=40)}


def test_at_sea_picks_shelter_near_port_and_routes_from_port():
    sent, asked = [], []

    def db(sql, params):
        asked.append((params.get("lat"), params.get("lon")))
        return flood_db(sql, params)

    d = L.collect(sea_state(), fetch=db, route_client=route_server(sent, sea=SEA))
    assert d.sea["port"]["name"] == "구룡포항"
    assert asked[-1] == (35.9915, 129.5575)                     # 대피소를 항구 육상 지점 기준으로 다시 고름
    assert d.chosen["name"] == "충혼탑 앞"
    assert sent[-1]["origin"] == {"lat": 35.9915, "lon": 129.5575}   # 도보 경로는 항구에서 출발
    keys = {e.key: e.value for e in d.evidence}
    assert keys["현재 위치"] == "해상(바다 위)" and keys["배를 댈 가장 가까운 항구"] == "구룡포항"
    assert keys["구룡포항까지 바닷길 거리"] == 1830 and keys["구룡포항 방향"] == "서남서쪽"
    assert keys["다른 가까운 항구"] == "삼정항"
    info = L.route_info(d)
    assert info["sea"]["port_name"] == "구룡포항" and info["sea"]["path"] == "xyz" and info["geometry"] == "abc"
    assert L.template_summary(d).startswith("지금 바다 위에 계십니다. 서남서쪽의 가장 가까운 항구 구룡포항까지 바닷길로 1830m")


def test_sea_path_not_found_gives_direction_only():
    sea = {**SEA, "sea_leg": {**SEA["sea_leg"], "path_found": False, "alternatives": []}}
    d = L.collect(sea_state(), fetch=flood_db, route_client=route_server(sea=sea))
    keys = {e.key: e.value for e in d.evidence}
    assert keys["구룡포항까지 직선거리"] == 1620 and "구룡포항까지 바닷길 거리" not in keys
    assert any("바닷길" in m for m in d.unavailable)
    assert "직선거리 1620m(바닷길은 찾지 못함)" in L.template_summary(d)


def test_on_land_uses_sea_endpoint_route_once():
    sent = []
    d = L.collect(sea_state() | {"current_location": Location(lat=35.9907, lon=129.5526)}, fetch=flood_db,
                  route_client=route_server(sent))
    assert d.sea is None and d.route["distance_m"] == 1024 and len(sent) == 1


def test_outside_sea_area_falls_back_to_plain_route():
    calls = []

    def handler(req):
        calls.append(req.url.path)
        if req.url.path == "/api/route/sea":
            return httpx.Response(422, json={"detail": "구룡포 일대 밖"})
        return httpx.Response(200, json=LAND_ROUTE)
    client = httpx.Client(base_url="http://route", transport=httpx.MockTransport(handler))
    d = L.collect(sea_state(), fetch=flood_db, route_client=client)
    assert calls == ["/api/route/sea", "/api/route"] and d.route["available"] and d.sea is None


def test_chat_response_carries_sea_leg():
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(fetch=flood_db, route_client=route_server(sea=SEA))})
    res = svc.chat(ChatRequest(user_id="u1", question="어디로 대피해야 해?", current_location=AT_SEA))
    assert res.route is not None and res.route.sea is not None
    assert res.route.sea.port_name == "구룡포항" and res.route.sea.bearing_label == "서남서쪽"
