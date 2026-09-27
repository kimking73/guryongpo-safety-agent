"""대피 경로 (목업) — 실구현은 B 의 GraphHopper (B6·B7)"""
from fastapi import APIRouter, Depends

from .. import mocks
from ..auth import AuthUser, current_user
from ..schemas import RouteCheckRequest, RouteRequest

router = APIRouter(tags=["route"])


@router.post("/route", summary="안전 대피 경로")
def post_route(body: RouteRequest, u: AuthUser = Depends(current_user)):
    return mocks.mock("route.json")


@router.post("/route/check", summary="이동 중 재검사 (30초 간격)")
def check_route(body: RouteCheckRequest, u: AuthUser = Depends(current_user)):
    return mocks.mock("route-check.json")
