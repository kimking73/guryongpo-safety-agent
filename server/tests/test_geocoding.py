from conftest import AUTH


def test_address_geocode_requires_auth(client):
    response = client.post("/api/v1/user/geocode", json={"address": "구룡포읍 호미로 152"})
    assert response.status_code == 401


def test_address_geocode_uses_kakao_on_server(client, monkeypatch):
    from app.routers import user

    seen = {}

    def fake(address):
        seen["address"] = address
        return {"address": "경북 포항시 남구 구룡포읍 호미로 152", "location": {"lat": 35.9859, "lng": 129.5492}}

    monkeypatch.setattr(user, "geocode_road_address", fake)
    response = client.post("/api/v1/user/geocode", headers=AUTH, json={"address": "구룡포읍 호미로 152"})
    assert response.status_code == 200
    assert seen["address"] == "구룡포읍 호미로 152"
    assert response.json() == {
        "address": "경북 포항시 남구 구룡포읍 호미로 152",
        "location": {"lat": 35.9859, "lng": 129.5492},
    }
