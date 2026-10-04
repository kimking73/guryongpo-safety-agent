"""A12 대피 확인 — 시간 규칙 · 응답 기록 · 재알림·이관 · 방재단 대피 현황 API (DB 없이, FakeDB)"""
from datetime import datetime, timedelta, timezone

import pytest

from conftest import AUTH
from test_alerts import ALERT, INCIDENT, UID, assert_spec

NOW = datetime(2026, 10, 5, 5, 30, tzinfo=timezone.utc)
STAFF = {"Authorization": "Bearer dev:responder-1"}
CAREGIVER = {"Authorization": "Bearer dev:caregiver-1"}
STAFF_ID = "11111111-2222-4333-8444-555555555555"
TARGET = "7a000000-0000-4000-8000-000000000001"
HH_TARGET = "7a000000-0000-4000-8000-000000000003"
HOUSEHOLD = "a9b8c7d6-e5f4-4a3b-9c2d-1e0f9a8b7c6d"


def mins(n):
    return NOW - timedelta(minutes=n)


# ------------------------------------------------------------------ 시간 규칙
def _t(status="no_response", created=0, **kw):
    return {"status": status, "created_at": mins(created), "status_at": None, "last_reminder_at": None,
            "escalated_at": None, "user_id": UID, "alert_id": ALERT, **kw}


@pytest.mark.parametrize("t,expected", [
    (_t(created=1), None),                                                     # 1분 — 아직
    (_t(created=2), "reminder"),                                               # 2분 — 첫 재알림
    (_t(created=5, last_reminder_at=mins(1)), None),                           # 재알림 1분 뒤
    (_t(created=9, last_reminder_at=mins(2)), "reminder"),
    (_t(created=10, last_reminder_at=mins(0)), "escalate"),                    # 10분 — 재알림보다 이관이 먼저
    (_t(created=15, escalated_at=mins(5), last_reminder_at=mins(6)), None),    # 이관 뒤엔 재알림 없음
    (_t("evacuating", created=12, status_at=mins(9)), None),
    (_t("evacuating", created=12, status_at=mins(10)), "reminder"),            # 대피 중 10분 → 재확인
    (_t("evacuating", created=30, status_at=mins(20), last_reminder_at=mins(10)), "reminder"),   # 10분마다
    (_t("evacuating", created=30, status_at=mins(20), last_reminder_at=mins(5)), None),
    (_t("evacuated", created=30, status_at=mins(20)), None),
    (_t("need_help", created=30, status_at=mins(20)), None),                   # 응답 즉시 이관했으므로 주기 처리 없음
    (_t(created=30, user_id=None), None),                                      # 앱 없는 등록 가구 → 방재단 목록만
])
def test_next_action(t, expected):
    from alerts.evacuation import next_action
    assert next_action(t, NOW) == expected


def test_run_followups(fake_db, monkeypatch):
    from alerts import evacuation
    fake_db.rows["WHERE t.status IN ('no_response', 'evacuating')"] = [
        {**_t(created=3), "id": "a"}, {**_t(created=11), "id": "b"}, {**_t(created=1), "id": "c"}]
    done = []
    monkeypatch.setattr(evacuation, "remind", lambda t: done.append(("remind", t["id"])))
    monkeypatch.setattr(evacuation, "escalate", lambda tid, why: done.append((why, tid)))
    assert evacuation.run_followups(now=NOW) == 2
    assert done == [("remind", "a"), ("no_response", "b")]


def test_escalate_payload(fake_db, monkeypatch):
    from alerts import evacuation, fcm
    fake_db.rows["UPDATE care.incident_targets t SET escalated_at"] = [
        {"id": TARGET, "incident_id": INCIDENT, "note": "다리를 다쳐 못 움직여요", "title": "침수 경보", "hazard": "flood",
         "level": "warning", "label": None}]
    fake_db.rows["u.role IN ('responder', 'admin')"] = [{"fcm_token": "t1"}, {"fcm_token": "t2"}]
    sent = []
    monkeypatch.setattr(fcm, "send", lambda p: sent.extend(p) or {})
    evacuation.escalate(TARGET, "need_help")
    assert [p.token for p in sent] == ["t1", "t2"]
    p = sent[0]
    assert p.title == "[도움 요청] 앱 사용자" and "다리를 다쳐" in p.body
    assert p.data == {"kind": "escalation", "incident_id": INCIDENT, "target_id": TARGET, "hazard": "flood",
                      "level": "warning", "level_num": "3", "action": "open_incident"}


def test_record_mirrors_linked_household(fake_db, monkeypatch):
    from alerts import evacuation
    fake_db.rows["WHERE t.incident_id = %(iid)s AND h.linked_user_id"] = [{"id": HH_TARGET}]
    esc = []
    monkeypatch.setattr(evacuation, "escalate", lambda tid, why: esc.append((tid, why)))
    ids = evacuation.record({"id": TARGET, "incident_id": INCIDENT, "user_id": UID}, "need_help", "button",
                            by_user_id=UID, location={"lat": 35.99, "lng": 129.55})
    assert ids == [TARGET, HH_TARGET]
    upd = next(p for sql, p in fake_db.executed if "UPDATE care.incident_targets SET status" in sql)
    assert upd["ids"] == [TARGET, HH_TARGET] and upd["lat"] == 35.99
    hist = next(rows for sql, rows in fake_db.executed if "INSERT INTO care.evacuation_responses" in sql)
    assert len(hist) == 2 and hist[0]["via"] == "button"
    assert esc == [(TARGET, "need_help")]


# ------------------------------------------------------------------ 주민: 대피 확인 응답
ALERT_ROW = {"response_required": True, "incident_id": INCIDENT, "user_id": UID, "closed_at": None, "incident_exists": True}


def _respond(client, **body):
    return client.post(f"/api/v1/alerts/{ALERT}/response", headers=AUTH, json={"via": "button", **body})


def test_response_records(client, fake_db, monkeypatch):
    from alerts import evacuation
    fake_db.rows["FROM user_alerts a JOIN users u ON u.id = a.user_id"] = [ALERT_ROW]
    fake_db.rows["INSERT INTO care.incident_targets (incident_id, user_id, alert_id)"] = [{"id": TARGET}]
    calls = []
    monkeypatch.setattr(evacuation, "record", lambda t, s, via, **kw: calls.append((t, s, via, kw)) or [t["id"]])
    r = _respond(client, status="evacuating")
    assert r.status_code == 200 and "X-Mock" not in r.headers
    assert_spec(r.json(), "/alerts/{alert_id}/response", "post")
    assert r.json()["recheck_after_min"] == 10 and r.json()["call_suggested"] is False
    assert calls[0][:3] == ({"id": TARGET, "incident_id": INCIDENT, "user_id": UID}, "evacuating", "button")
    assert _respond(client, status="need_help").status_code == 422                     # 위치 필수
    r = _respond(client, status="need_help", via="voice", transcript="살려주세요", location={"lat": 35.99, "lng": 129.55})
    assert r.json()["call_suggested"] is True and calls[-1][2] == "voice" and calls[-1][3]["note"] == "음성: 살려주세요"
    assert _respond(client, status="no_response").status_code == 422                   # 앱이 보낼 수 없는 상태


def test_response_errors(client, fake_db):
    assert _respond(client, status="evacuated").status_code == 404
    fake_db.rows["FROM user_alerts a JOIN users u ON u.id = a.user_id"] = [{**ALERT_ROW, "response_required": False}]
    assert _respond(client, status="evacuated").status_code == 422
    fake_db.rows["FROM user_alerts a JOIN users u ON u.id = a.user_id"] = [{**ALERT_ROW, "closed_at": NOW}]
    r = _respond(client, status="evacuated")
    assert r.status_code == 409 and r.json()["code"] == "CONFLICT"


def test_dashboard_evacuation_is_real(client, fake_db):
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": UID}]
    fake_db.rows["WHERE t.user_id = %(uid)s AND t.household_id IS NULL"] = [
        {"incident_id": INCIDENT, "alert_id": ALERT, "hazard": "flood", "level": "warning", "title": "침수 경보",
         "status": "evacuating", "status_at": NOW, "started_at": NOW}]
    d = client.get("/api/v1/dashboard", headers=AUTH, params={"lat": 35.99, "lng": 129.55, "scenario": "emergency"}).json()
    assert_spec(d, "/dashboard")
    assert d["evacuation"]["status"] == "evacuating"
    fake_db.rows.clear()
    d = client.get("/api/v1/dashboard", headers=AUTH, params={"lat": 35.99, "lng": 129.55, "scenario": "emergency"}).json()
    assert d["evacuation"] is None                                     # 진행 중 대피 상황 없음 → 카드 없음


# ------------------------------------------------------------------ 방재단
INC_ROW = {"id": INCIDENT, "hazard": "flood", "level": "warning", "title": "침수 경보 (포항 DT 4단계)", "source": "simulated",
           "area_id": 12, "started_at": NOW, "closed_at": None,
           "area_geojson": '{"type":"MultiPolygon","coordinates":[[[[129.55,35.98],[129.56,35.98],[129.56,35.99],[129.55,35.98]]]]}',
           "total": 2, "no_response": 1, "evacuating": 0, "evacuated": 0, "need_help": 1}
BASE_T = {"reminder_count": 0, "escalated_at": None, "priority_score": None, "priority_reasons": [], "note": None,
          "created_at": datetime.now(timezone.utc) - timedelta(minutes=7, seconds=30), "alert_at": None, "status_via": None, "status_at": None,
          "assigned_to": None, "assigned_nickname": None, "last_lat": None, "last_lng": None, "v_id": None}
TARGET_ROWS = [
    {**BASE_T, "id": HH_TARGET, "household_id": HOUSEHOLD, "user_id": None, "status": "no_response", "label": "병포리 최OO 댁",
     "address": "구룡포읍", "phone": "010-0000-0001", "needs": ["elderly", "wheelchair"], "linked_user_id": None,
     "lat": 35.9908, "lng": 129.5566, "v_id": 7, "v_at": NOW, "v_result": "not_home", "v_status_after": "no_response",
     "v_note": None, "v_responder": STAFF_ID, "v_responder_nick": "방재단 김OO"},
    {**BASE_T, "id": TARGET, "household_id": None, "user_id": UID, "status": "need_help", "status_via": "button",
     "status_at": NOW, "label": None, "address": None, "phone": None, "needs": None, "linked_user_id": None,
     "lat": 35.9906, "lng": 129.5561, "last_lat": 35.9906, "last_lng": 129.5561, "escalated_at": NOW,
     "note": "다리를 다쳐 못 움직여요", "assigned_to": STAFF_ID, "assigned_nickname": "방재단 김OO"},
]


@pytest.fixture
def admin_db(fake_db):
    fake_db.rows["INSERT INTO users (firebase_uid"] = [{"id": STAFF_ID, "created": False}]
    fake_db.rows["LEFT JOIN care.incident_targets t ON t.incident_id = i.id"] = [INC_ROW]
    fake_db.rows["FROM care.incident_targets t\nJOIN care.incidents i ON i.id = t.incident_id"] = TARGET_ROWS
    return fake_db


def test_admin_incident_detail(client, admin_db):
    d = client.get(f"/api/v1/admin/incidents/{INCIDENT}", headers=STAFF).json()
    assert_spec(d, "/admin/incidents/{incident_id}")
    assert [t["id"] for t in d["targets"]] == [TARGET, HH_TARGET]          # 도움 필요 먼저
    assert [t["priority_rank"] for t in d["targets"]] == [1, 2]
    me, hh = d["targets"]
    assert me["kind"] == "app_user" and me["label"] == "앱 사용자 (가구 미등록)" and me["escalated"] and me["assigned_to"]["is_me"]
    assert hh["kind"] == "household" and hh["minutes_since_alert"] == 7 and not hh["has_app"]
    assert hh["last_visit"]["result"] == "not_home" and hh["last_visit"]["responder"]["nickname"] == "방재단 김OO"
    assert d["rules"] == {"reminder_interval_min": 2, "escalate_after_min": 10, "evacuating_recheck_min": 10}
    assert d["summary"]["need_help"] == 1 and d["next_poll_sec"] == 10
    assert_spec(client.get("/api/v1/admin/incidents", headers=STAFF).json(), "/admin/incidents")
    m = client.get(f"/api/v1/admin/incidents/{INCIDENT}/map", headers=STAFF).json()
    assert [f["properties"]["kind"] for f in m["features"]] == ["area", "target", "target"]
    ov = client.get("/api/v1/admin/overview", headers=STAFF).json()
    assert_spec(ov, "/admin/overview") and ov["active_incidents"][0]["id"] == INCIDENT


def test_admin_not_found(client, fake_db):
    fake_db.rows["INSERT INTO users (firebase_uid"] = [{"id": STAFF_ID, "created": False}]
    assert client.get(f"/api/v1/admin/incidents/{INCIDENT}", headers=STAFF).status_code == 404


def test_caregiver_sees_only_own_households(client, admin_db, monkeypatch):
    from app import db
    seen = []
    orig = db.fetch_all
    monkeypatch.setattr(db, "fetch_all", lambda sql, p=None: seen.append(p) or orig(sql, p))
    client.get(f"/api/v1/admin/incidents/{INCIDENT}", headers=CAREGIVER)
    assert any(p and p.get("cg") == STAFF_ID for p in seen)            # 생활지원사 본인 id 로 거름
    client.get(f"/api/v1/admin/incidents/{INCIDENT}", headers=STAFF)
    assert seen[-1].get("cg") is None


def test_admin_patch_target(client, admin_db, monkeypatch):
    from alerts import evacuation
    calls = []
    monkeypatch.setattr(evacuation, "record", lambda t, s, via, **kw: calls.append((t, s, via, kw)))
    r = client.patch(f"/api/v1/admin/incidents/{INCIDENT}/targets/{HH_TARGET}", headers=STAFF,
                     json={"status": "evacuated", "assigned_to": "me"})
    assert r.status_code == 200
    assert_spec(r.json(), "/admin/incidents/{incident_id}/targets/{target_id}", "patch")
    assert calls == [({"id": HH_TARGET, "incident_id": INCIDENT, "user_id": None}, "evacuated", "responder",
                      {"by_user_id": STAFF_ID, "note": None})]
    assign = next(p for sql, p in admin_db.executed if "SET assigned_to" in sql)
    assert assign == {"a": STAFF_ID, "tid": HH_TARGET}
    assert client.patch(f"/api/v1/admin/incidents/{INCIDENT}/targets/{HH_TARGET}", headers=STAFF,
                        json={"assigned_to": "someone"}).status_code == 422
    admin_db.rows["LEFT JOIN care.incident_targets t ON t.incident_id = i.id"] = [{**INC_ROW, "closed_at": NOW}]
    assert client.patch(f"/api/v1/admin/incidents/{INCIDENT}/targets/{HH_TARGET}", headers=STAFF,
                        json={"status": "evacuated"}).status_code == 409


def test_admin_close_and_create(client, admin_db, monkeypatch):
    from alerts import dispatch
    closed, started = [], []
    monkeypatch.setattr(dispatch, "push_closed", lambda c: closed.extend(c))
    monkeypatch.setattr(dispatch, "start_manual", lambda *a: started.append(a) or 0)
    assert client.post(f"/api/v1/admin/incidents/{INCIDENT}/close", headers=CAREGIVER).status_code == 403
    r = client.post(f"/api/v1/admin/incidents/{INCIDENT}/close", headers=STAFF)
    assert r.status_code == 200 and closed == [{"id": INCIDENT, "title": INC_ROW["title"]}]
    assert any("SET closed_at = now()" in sql for sql, _ in admin_db.executed)

    admin_db.rows["INSERT INTO care.incidents (hazard, level, title, area, source, created_by, note)"] = [{"id": INCIDENT}]
    body = {"hazard": "landslide", "level": "warning", "title": "삼정리 산사태 대피", "message": "삼정리 주민은 구룡포초로 대피",
            "area": {"center": {"lat": 35.97, "lng": 129.55}, "radius_m": 500}}
    r = client.post("/api/v1/admin/incidents", headers=STAFF, json=body)
    assert r.status_code == 201
    assert_spec(r.json(), "/admin/incidents", "post", "201")
    assert started == [(INCIDENT, "landslide", "warning", "삼정리 산사태 대피", "삼정리 주민은 구룡포초로 대피")]
    assert client.post("/api/v1/admin/incidents", headers=CAREGIVER, json=body).status_code == 403


def test_manual_notice_in_message():
    from alerts.messages import compose
    m = compose({"kind": "evacuation", "hazard": "landslide", "level": "warning", "reason": "삼정리 산사태 대피",
                 "notice": "삼정리 주민은 구룡포초로 대피"}, {"trigger": "place", "place_label": "우리집"})
    assert m["body"].startswith("방재단 안내: 삼정리 주민은 구룡포초로 대피")
