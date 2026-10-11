"""방재단 배정 → 주민 도착 예상 시간 안내 (alerts/assignment.py, DB 없이 FakeDB)"""
import httpx

from test_evacuation import INCIDENT, STAFF, STAFF_ID, TARGET, admin_db  # noqa: F401 — fixture 재사용

RESP_LOC = (35.9930, 129.5560)
TARGET_ROW = {"id": TARGET, "lat": 35.9906, "lng": 129.5561}


def test_straight_eta_and_minutes():
    from alerts import assignment as A
    s = A.straight_eta_s(RESP_LOC, (TARGET_ROW["lat"], TARGET_ROW["lng"]))     # 약 267m → ×1.3 ÷ 1.2 ≈ 289초
    assert 270 <= s <= 310
    assert A.eta_minutes(s) == 5 and A.eta_minutes(10) == 1 and A.eta_minutes(None) is None
    assert "약 5분 후 도착" in A.tts_text(5) and "곧 찾아갑니다" in A.tts_text(None)


def test_route_eta_uses_route_service(monkeypatch):
    from alerts import assignment as A
    from app.config import settings
    seen = []

    def handler(req):
        seen.append((str(req.url), req.content))
        return httpx.Response(200, json={"duration_s": 412})
    http = httpx.Client(transport=httpx.MockTransport(handler))
    object.__setattr__(settings, "route_url", "http://route:8002")
    try:
        assert A.route_eta_s(RESP_LOC, (1.0, 2.0), http=http) == 412
        assert seen[0][0] == "http://route:8002/api/route" and b'"mode":"walk"' in seen[0][1]
        down = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(503)))
        assert A.route_eta_s(RESP_LOC, (1.0, 2.0), http=down) is None
    finally:
        object.__setattr__(settings, "route_url", None)
    assert A.route_eta_s(RESP_LOC, (1.0, 2.0)) is None                       # 설정 없음 → 직선거리로


def test_on_assigned_saves_eta_and_pushes_resident(fake_db, monkeypatch):
    from alerts import assignment as A, fcm
    fake_db.rows["FROM user_devices\nWHERE user_id"] = [{"lat": RESP_LOC[0], "lng": RESP_LOC[1]}]
    fake_db.rows["SELECT DISTINCT d.fcm_token FROM care.incident_targets t"] = [{"fcm_token": "tok-resident"}]
    sent = []
    monkeypatch.setattr(fcm, "send", lambda p: sent.extend(p) or {"sent": len(p)})
    monkeypatch.setattr(A, "route_eta_s", lambda a, b: 412)
    out = A.on_assigned(INCIDENT, TARGET_ROW, STAFF_ID)
    assert out["eta_s"] == 412 and out["eta_min"] == 7
    save = next(p for sql, p in fake_db.executed if "assignee_eta_s" in sql)
    assert save == {"assigned": True, "eta": 412, "tid": TARGET}
    (p,) = sent
    assert p.token == "tok-resident" and p.data["kind"] == "responder_assigned" and p.data["eta_min"] == "7"
    assert p.data["incident_id"] == INCIDENT and "약 7분 후 도착" in p.data["tts_text"]
    assert not fcm.is_alarm(p.data)                                          # 사이렌 아님 — 일반 알림


def test_on_assigned_without_location_and_unassign(fake_db, monkeypatch):
    from alerts import assignment as A, fcm
    fake_db.rows["SELECT DISTINCT d.fcm_token FROM care.incident_targets t"] = [{"fcm_token": "tok"}]
    sent = []
    monkeypatch.setattr(fcm, "send", lambda p: sent.extend(p) or {})
    assert A.on_assigned(INCIDENT, TARGET_ROW, STAFF_ID)["eta_min"] is None     # 방재단원 위치 모름
    assert "eta_min" not in sent[0].data and "곧 찾아갑니다" in sent[0].data["tts_text"]
    fake_db.executed.clear()
    sent.clear()
    assert A.on_assigned(INCIDENT, TARGET_ROW, None)["push"] is None              # 해제 → 비우기만
    assert fake_db.executed[0][1] == {"assigned": False, "eta": None, "tid": TARGET} and not sent


def test_admin_patch_assign_calls_hook(client, admin_db, monkeypatch):
    from alerts import assignment
    from test_evacuation import TARGET_ROWS
    calls = []
    monkeypatch.setattr(assignment, "on_assigned", lambda iid, t, rid: calls.append((iid, t["id"], rid)))
    key = "FROM care.incident_targets t\nJOIN care.incidents i ON i.id = t.incident_id"
    hh, mine = TARGET_ROWS                         # hh: 담당 없음, mine: 이미 내가 맡음 (FakeDB 는 첫 행을 돌려줌)
    url = f"/api/v1/admin/incidents/{INCIDENT}/targets/{TARGET}"
    admin_db.rows[key] = [hh, mine]
    client.patch(url, headers=STAFF, json={"assigned_to": "me"})       # 새로 맡음 → 알림
    admin_db.rows[key] = [mine, hh]
    client.patch(url, headers=STAFF, json={"assigned_to": "me"})       # 이미 내 대상 → 알림 없음
    client.patch(url, headers=STAFF, json={"assigned_to": None})       # 해제 → 비우기
    assert calls == [(INCIDENT, hh["id"], STAFF_ID), (INCIDENT, mine["id"], None)]


def test_my_evacuation_eta_counts_down(fake_db):
    from datetime import datetime, timedelta, timezone
    from app import incidents
    now = datetime.now(timezone.utc)
    base = {"incident_id": INCIDENT, "alert_id": INCIDENT, "hazard": "flood", "level": "warning", "title": "t",
            "status": "evacuating", "status_at": None, "started_at": now}
    fake_db.rows["ORDER BY i.level DESC"] = [{**base, "assigned_to": STAFF_ID, "assigned_at": now - timedelta(minutes=3),
                                              "assignee_eta_s": 420}]
    e = incidents.my_evacuation("u")
    assert e["assigned"] and e["eta_min"] == 4                                 # 7분 중 3분 지남
    fake_db.rows["ORDER BY i.level DESC"] = [{**base, "assigned_to": None, "assigned_at": None, "assignee_eta_s": None}]
    assert incidents.my_evacuation("u")["assigned"] is False
