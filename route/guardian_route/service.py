"""경로 안내: 요청 형식, GraphHopper 호출, 응답 형식.

응답 키는 AI tool `request_route`(ai/guardian_ai/tools.py)와 같은 계약이다 (ai/docs/agent-design.md 5절).
B6 1단계는 도보 최단 경로만 계산한다. 위험 구역·맨홀 회피(avoided)는 B6 2단계, profile별 가중치는 B7.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field

from .gh import GraphHopperClient

Profile = Literal["adult", "elderly", "wheelchair"]


class LatLon(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: LatLon
    destination: LatLon
    profile: Profile = "adult"      # 지금은 받기만 하고 모두 같은 도보 경로 (B7에서 분기)


class RouteResponse(BaseModel):
    profile: Profile
    distance_m: int
    duration_s: int
    avoided: list[str] = Field(default_factory=list)   # 우회한 위험 구역 id (B6 2단계부터 채운다)
    geometry: str                                       # 인코딩된 polyline (Google 형식, 정밀도 1e5, lat·lon 순)
    source: str = "graphhopper"


class RouteService:
    def __init__(self, client: GraphHopperClient | None = None):
        self.gh = client or GraphHopperClient()

    def route(self, req: RouteRequest) -> RouteResponse:
        """경로를 계산한다. GraphHopperUnavailable, RouteNotFound 예외는 api.py가 HTTP 오류로 바꾼다."""
        path = self.gh.route([(req.origin.lat, req.origin.lon), (req.destination.lat, req.destination.lon)])
        return RouteResponse(
            profile=req.profile,
            distance_m=round(path["distance"]),
            duration_s=round(path["time"] / 1000),     # GraphHopper time은 밀리초
            geometry=path["points"],
        )

    def health(self) -> dict:
        return {"status": "ok", "graphhopper": "ok" if self.gh.ping() else "error"}
