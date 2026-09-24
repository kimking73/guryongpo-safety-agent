"""agent가 쓰는 DB 조회 tool 명세 + 목업 구현.

반환 형식은 A1(API 명세)과 합의할 대상이다. 실제 구현은 A의 DB/엔드포인트가
준비되면 각 함수 본문만 교체한다 (시그니처와 반환 키는 유지).
좌표는 WGS84(lat, lon), 시간은 ISO 8601(KST, +09:00).
"""

from __future__ import annotations

from typing import Any, Literal

HazardKind = Literal["landslide", "flood"]
FacilityKind = Literal["shelter", "medical", "manhole"]
ObservationKind = Literal["rain", "wind", "water_level", "wave", "tide"]

# 목업 기준 시각
_NOW = "2026-09-23T20:00:00+09:00"


def get_risk_at(lat: float, lon: float, radius_m: int = 500) -> list[dict[str, Any]]:
    """좌표 주변의 최신 위험 판정 (Risk engine 결과, 테이블: risk_assessments).

    사용: 관리자(재난 단계 판정), 모든 전문 agent
    """
    return [
        {"disaster": "flood", "level": "warning", "lat": 35.9905, "lon": 129.5560,
         "distance_m": 180, "reason": "수위 22cm (기준 15cm 초과)", "assessed_at": _NOW},
    ]


def get_observations(kind: ObservationKind, lat: float, lon: float) -> dict[str, Any]:
    """가장 가까운 관측소의 최신 관측값 (테이블: observations).

    출처: 포항 디지털 트윈(수위·풍속), 기상청 지상관측(강수·기온·풍향).
    사용: 호우/침수, 강풍/태풍 agent
    """
    mock = {
        "rain": {"value": 42.0, "unit": "mm/h", "source": "kma.asos"},
        "wind": {"value": 14.2, "unit": "m/s", "source": "pohang_twin.wind"},
        "water_level": {"value": 22.0, "unit": "cm", "source": "pohang_twin.water_level"},
        "wave": {"value": 2.8, "unit": "m", "source": "pohang_twin.wave"},
        "tide": {"value": "21:12 만조", "unit": None, "source": "khoa.tide"},
    }[kind]
    return {"kind": kind, "station": "구룡포", **mock, "observed_at": _NOW}


def get_weather_warnings(region: str = "포항") -> list[dict[str, Any]]:
    """발효 중·예정·해제된 기상특보 (테이블: weather_warnings, 출처: 기상청).

    status: "planned"(예비특보) | "active" | "lifted"
    사용: 관리자(재난 단계 판정), 호우/침수, 강풍/태풍 agent
    """
    return [
        {"type": "heavy_rain", "level": "warning", "status": "active",
         "issued_at": "2026-09-23T18:00:00+09:00", "lifted_at": None, "source": "kma.warning"},
    ]


def get_disaster_messages(region: str = "포항", hours: int = 6) -> list[dict[str, Any]]:
    """최근 재난문자 (테이블: disaster_messages, 출처: 재난안전24)."""
    return [
        {"sent_at": "2026-09-23T19:40:00+09:00", "sender": "포항시",
         "text": "구룡포읍 저지대 침수 우려, 주민께서는 대피소로 이동 바랍니다.",
         "source": "safety24.message"},
    ]


def get_hazard_zones(kind: HazardKind, lat: float, lon: float, radius_m: int = 1000) -> list[dict[str, Any]]:
    """위험지역 폴리곤 중 좌표 반경에 걸친 것 (테이블: hazard_zones, PostGIS).

    출처: 산사태 위험지역(공공데이터포털), 침수 위험지역(포항 디지털 트윈).
    사용: 산사태 agent, 호우/침수 agent, 경로 엔진
    """
    return [
        {"zone_id": f"{kind}-001", "kind": kind, "grade": "1등급",
         "contains_point": kind == "flood", "distance_m": 0 if kind == "flood" else 420,
         "source": f"hazard.{kind}"},
    ]


def get_facilities(kind: FacilityKind, lat: float, lon: float, limit: int = 5) -> list[dict[str, Any]]:
    """가까운 시설 (테이블: facilities). 출처: 생활안전지도, 포항 디지털 트윈(맨홀)."""
    return [
        {"facility_id": f"{kind}-001", "kind": kind, "name": "구룡포 실내체육관",
         "lat": 35.9921, "lon": 129.5512, "distance_m": 1200, "phone": "054-000-0000",
         "source": f"facility.{kind}"},
    ][:limit]


def get_life_safety(lat: float, lon: float) -> dict[str, Any]:
    """미세먼지·초미세먼지·자외선 최신값과 등급 (테이블: observations).

    등급 기준: 대기환경보전법(미세먼지), 기상청 5단계(자외선).
    """
    return {
        "pm10": {"value": 35, "unit": "㎍/㎥", "grade": "보통"},
        "pm25": {"value": 18, "unit": "㎍/㎥", "grade": "보통"},
        "uv": {"value": 2, "unit": None, "grade": "낮음"},
        "observed_at": _NOW, "source": "pohang_twin.air",
    }


def get_user_profile(user_id: str) -> dict[str, Any]:
    """사용자 정보 (테이블: users). UserProfile 모델과 같은 키."""
    return {
        "user_id": user_id, "user_type": "resident",
        "home": {"lat": 35.9905, "lon": 129.5560, "label": "집"},
        "age": 67, "mobility": "walk", "occupation": "어업(선박 보유)",
    }


def request_route(
    origin: tuple[float, float],
    destination: tuple[float, float],
    profile: Literal["adult", "elderly", "wheelchair"] = "adult",
) -> dict[str, Any]:
    """위험 회피 경로 (B6/B7 GraphHopper, 엔드포인트: /route).

    회피: 침수·산사태 위험지역, 침수 시 맨홀. profile에 따라 오르막 가중치.
    """
    return {
        "profile": profile, "distance_m": 1200, "duration_s": 1140,
        "avoided": ["flood-001", "manhole-003"],
        "geometry": "encoded-polyline", "source": "graphhopper",
    }


def get_action_guides(
    disaster: str, phase: str, audience: str = "general",
) -> list[dict[str, Any]]:
    """행동요령 원문 (테이블: action_guides, ActionGuide 모델과 같은 키).

    원문 수집 전까지는 목업. 행동 권고 agent는 여기 있는 문장만 인용한다.
    """
    return [
        {"id": f"{disaster}.{phase}.{audience}.01", "disaster": disaster, "phase": phase,
         "audience": audience, "text": "(원문 수집 예정)",
         "source_name": "포항시 재난안전", "source_url": "TBD"},
    ]


# agent별로 쓸 수 있는 tool. B2에서 LLM tool 바인딩에 그대로 사용한다.
AGENT_TOOLS: dict[str, list] = {
    "manager": [get_risk_at, get_weather_warnings, get_user_profile],
    "landslide_agent": [get_risk_at, get_hazard_zones, get_observations, get_weather_warnings],
    "rain_flood_agent": [get_risk_at, get_observations, get_hazard_zones, get_weather_warnings,
                         get_disaster_messages, get_facilities],
    "wind_typhoon_agent": [get_risk_at, get_observations, get_weather_warnings, get_disaster_messages],
    "life_safety_agent": [get_life_safety],
    "location_route_agent": [get_risk_at, get_facilities, request_route],
    "action_advisor": [get_action_guides, get_facilities],
}
