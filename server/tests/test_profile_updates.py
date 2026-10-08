"""AI 대화 → 프로필 수집 기록 API (care.profile_updates, 2026-10-08)"""
from datetime import datetime, timezone

from conftest import AUTH

UID = "11111111-1111-1111-1111-111111111111"


def test_add_list_delete(client, fake_db):
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": UID}]
    r = client.post("/api/v1/user/profile-updates", headers=AUTH, json={"items": [
        {"field": "age", "label": "나이", "value": "72세", "quote": "저 72살이에요"},
        {"field": "home_address", "label": "집 주소", "value": "구룡포시장 바로 뒤"}]})
    assert r.status_code == 201 and r.json() == {"added": 2}
    sql, rows = fake_db.executed[-1]
    assert "care.profile_updates" in sql and rows[0]["uid"] == UID and rows[0]["source"] == "ai_chat"
    assert rows[1]["quote"] is None

    fake_db.rows["FROM care.profile_updates"] = [{"id": 7, "field": "age", "label": "나이", "value": "72세", "quote": "저 72살이에요",
                                                 "source": "ai_chat", "created_at": datetime(2026, 10, 8, 1, tzinfo=timezone.utc)}]
    items = client.get("/api/v1/user/profile-updates", headers=AUTH).json()["items"]
    assert items[0]["id"] == 7 and items[0]["quote"] == "저 72살이에요" and items[0]["created_at"].startswith("2026-10-08")

    assert client.delete("/api/v1/user/profile-updates/7", headers=AUTH).status_code == 204
    assert "DELETE FROM care.profile_updates" in fake_db.executed[-1][0]


def test_needs_login_and_items(client, fake_db):
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": UID}]
    assert client.get("/api/v1/user/profile-updates").status_code == 401
    assert client.post("/api/v1/user/profile-updates", headers=AUTH, json={"items": []}).status_code in (400, 422)
