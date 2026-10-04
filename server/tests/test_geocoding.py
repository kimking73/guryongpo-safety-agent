from conftest import AUTH
from types import SimpleNamespace

import pytest


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


def test_geocoder_requires_road_address_result(monkeypatch):
    from app import geocoding
    from app.errors import ApiError

    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return {"documents": [{"address_name": "parcel only", "x": "129.55", "y": "35.99"}]}

    monkeypatch.setattr(geocoding, "settings", SimpleNamespace(kakao_rest_key="test-key"))
    monkeypatch.setattr(geocoding.httpx, "get", lambda *args, **kwargs: FakeResponse())
    with pytest.raises(ApiError, match="도로명 주소 결과"):
        geocoding.geocode_road_address("구룡포 주소")


def test_place_creation_geocodes_road_address_and_persists_coordinates(client, fake_db, monkeypatch):
    from app.routers import user

    # 등록된 사용자 + 저장 후 다시 읽는 장소 (DB 없이 FakeDB)
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": "3f2a1c9e-8b7d-4e6f-a5c4-1d2e3f4a5b6c"}]
    fake_db.rows["INSERT INTO user_places"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20"}]
    fake_db.rows["FROM user_places pl"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20", "place_type": "home", "label": "집",
                                            "address": "경북 포항시 남구 구룡포읍 호미로 152", "notify": True,
                                            "lat": 35.9859, "lng": 129.5492, "in_hazard_zones": []}]

    monkeypatch.setattr(
        user,
        "geocode_road_address",
        lambda address: {
            "address": "경북 포항시 남구 구룡포읍 호미로 152",
            "location": {"lat": 35.9859, "lng": 129.5492},
        },
    )
    response = client.post(
        "/api/v1/user/places",
        headers=AUTH,
        json={
            "place_type": "home",
            "label": "집",
            "address": "구룡포읍 호미로 152",
        },
    )
    assert response.status_code == 201
    assert response.json()["address"] == "경북 포항시 남구 구룡포읍 호미로 152"
    assert response.json()["location"] == {"lat": 35.9859, "lng": 129.5492}
