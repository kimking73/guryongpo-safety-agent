"""사용자 · 장소 · 비상연락처 · 체크리스트 · 기기 토큰 — 인증 필요, 현재 목업 (실구현 A5)"""
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, Response

from .. import mocks
from ..auth import AuthUser, current_user
from ..schemas import DeviceTokenInput, EmergencyContactInput, PlaceInput, PlacePatch, ProfileInput

router = APIRouter(tags=["user"])


def _user(u: AuthUser) -> dict:
    d = mocks.load("user.json")
    d["firebase_uid"] = u.uid            # 호출한 사람의 uid 로 바꿔서 반환 (앱이 uid 일치를 확인할 수 있게)
    return d


@router.post("/user", status_code=201, summary="첫 실행 등록 (uid 기준 멱등)")
def register_user(body: Optional[ProfileInput] = None, u: AuthUser = Depends(current_user)):
    return mocks.respond(_user(u), 201)


@router.get("/user", summary="내 정보")
def get_user(u: AuthUser = Depends(current_user)):
    return mocks.respond(_user(u))


@router.patch("/user", summary="인적사항 부분 수정")
def update_user(body: ProfileInput, u: AuthUser = Depends(current_user)):
    d = _user(u)
    d["profile"].update(body.model_dump(exclude_unset=True))
    return mocks.respond(d)


@router.delete("/user", status_code=204, summary="탈퇴")
def delete_user(u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/user/places", status_code=201, summary="장소 추가")
def add_place(body: PlaceInput, u: AuthUser = Depends(current_user)):
    return mocks.respond({"id": str(uuid.uuid4()), **body.model_dump(), "in_hazard_zones": []}, 201)


@router.patch("/user/places/{place_id}", summary="장소 수정")
def update_place(place_id: uuid.UUID, body: PlacePatch, u: AuthUser = Depends(current_user)):
    base = next((p for p in _user(u)["places"] if p["id"] == str(place_id)), None)
    if base is None:
        from ..errors import ApiError
        raise ApiError("NOT_FOUND")
    base.update(body.model_dump(exclude_unset=True))
    return mocks.respond(base)


@router.delete("/user/places/{place_id}", status_code=204, summary="장소 삭제")
def delete_place(place_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/user/contacts", status_code=201, summary="비상연락처 추가")
def add_contact(body: EmergencyContactInput, u: AuthUser = Depends(current_user)):
    return mocks.respond({"id": str(uuid.uuid4()), **body.model_dump()}, 201)


@router.delete("/user/contacts/{contact_id}", status_code=204, summary="비상연락처 삭제")
def delete_contact(contact_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.put("/user/checklist/{item_id}", status_code=204, summary="체크리스트 체크")
def check_item(item_id: int, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.delete("/user/checklist/{item_id}", status_code=204, summary="체크리스트 해제")
def uncheck_item(item_id: int, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/device-token", summary="FCM 토큰 등록 → device_id")
def register_device_token(body: DeviceTokenInput, u: AuthUser = Depends(current_user)):
    # 같은 uid+토큰이면 같은 device_id (앱 재시작 시 폴링 device_id 유지) — 실구현은 user_devices 테이블
    return mocks.respond({"device_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"{u.uid}|{body.token}"))})


@router.delete("/device-token", status_code=204, summary="FCM 토큰 해제")
def delete_device_token(token: str, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})
