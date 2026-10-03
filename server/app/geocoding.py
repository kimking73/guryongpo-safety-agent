"""서버 전용 카카오 도로명 주소 좌표 변환."""
from __future__ import annotations

import httpx

from .config import settings
from .errors import ApiError

KAKAO_ADDRESS_URL = "https://dapi.kakao.com/v2/local/search/address.json"


def geocode_road_address(address: str) -> dict:
    query = address.strip()
    if not query:
        raise ApiError("VALIDATION_ERROR", "도로명 주소를 입력해 주세요.")
    if not settings.kakao_rest_key:
        raise ApiError("UPSTREAM_UNAVAILABLE", "주소 변환 설정이 없어 좌표를 확인할 수 없습니다.")

    try:
        response = httpx.get(
            KAKAO_ADDRESS_URL,
            params={"query": query},
            headers={"Authorization": f"KakaoAK {settings.kakao_rest_key}"},
            timeout=5.0,
        )
        response.raise_for_status()
        payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise ApiError("UPSTREAM_UNAVAILABLE", "카카오 주소 검색에 연결하지 못했습니다. 잠시 후 다시 시도해 주세요.") from exc

    documents = payload.get("documents") or []
    if not documents:
        raise ApiError("NOT_FOUND", "입력한 주소를 찾을 수 없습니다. 도로명 주소를 확인해 주세요.")

    result = documents[0]
    road = result.get("road_address")
    normalized = (road or {}).get("address_name") or result.get("address_name")
    if not normalized:
        raise ApiError("NOT_FOUND", "도로명 주소 결과가 없습니다. 도로명 주소를 확인해 주세요.")
    try:
        lng, lat = float(result["x"]), float(result["y"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ApiError("UPSTREAM_UNAVAILABLE", "주소 좌표를 확인할 수 없습니다. 다시 시도해 주세요.") from exc

    return {"address": normalized, "location": {"lat": lat, "lng": lng}}
