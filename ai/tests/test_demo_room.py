"""시연 방 (demo_room.py, 2026-10-12): 다른 계정의 사용자 모드 ↔ 방재단원 모드 창을 잇는다"""

from fastapi.testclient import TestClient

from guardian_ai import api
from guardian_ai.demo_room import TTL_S, DemoRoomPatch, DemoRooms


def test_patch_changes_only_sent_fields_and_null_clears():
    rooms = DemoRooms()
    rooms.patch("AB12", DemoRoomPatch(alert_active=True, response="need_help", needs=["mobility_limited"]))
    r = rooms.patch("AB12", DemoRoomPatch.model_validate(
        {"dispatch": {"departed_at": "2026-10-12T10:00:00", "eta": "2026-10-12T10:06:00"}}))
    assert r.alert_active and r.response == "need_help" and r.needs == ["mobility_limited"]   # 안 보낸 칸은 그대로
    assert r.dispatch.stage == "en_route" and r.version == 2
    r = rooms.patch("AB12", DemoRoomPatch.model_validate({"response": None, "dispatch": None}))
    assert r.response is None and r.dispatch is None and r.alert_active


def test_unknown_room_is_empty_and_rooms_expire():
    now = [1000.0]
    rooms = DemoRooms(clock=lambda: now[0])
    assert rooms.get("ZZZZ").version == 0 and not rooms.get("ZZZZ").alert_active
    rooms.patch("ZZZZ", DemoRoomPatch(alert_active=True))
    now[0] += TTL_S + 1
    assert rooms.get("ZZZZ").version == 0


def test_api_round_trip_and_validation():
    api.app.dependency_overrides[api.get_demo_rooms] = lambda: shared
    shared = DemoRooms()
    try:
        c = TestClient(api.app)
        assert c.put("/api/ai/demo-room/K7Q2", json={"alert_active": True, "response": "evacuating", "needs": ["vision"]}).status_code == 200
        got = c.get("/api/ai/demo-room/K7Q2").json()
        assert got["response"] == "evacuating" and got["needs"] == ["vision"] and got["version"] == 1
        assert c.get("/api/ai/demo-room/bad code").status_code == 422          # 코드는 대문자·숫자 4~8자
        assert c.put("/api/ai/demo-room/K7Q2", json={"response": "lost"}).status_code == 422
        assert c.put("/api/ai/demo-room/K7Q2", json={"needs": ["address"]}).status_code == 422   # 장애 유형 외엔 받지 않는다
    finally:
        api.app.dependency_overrides.clear()
